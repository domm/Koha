package Koha::BackgroundJob::MARCImport;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;
use JSON qw( encode_json decode_json );

use Koha::BackgroundJobs;
use Koha::DateUtils qw( dt_from_string );
use C4::Biblio;
use C4::MarcModificationTemplates;
use C4::Context;
use C4::ImportBatch;

use base 'Koha::BackgroundJob';

=head1 NAME

Koha::BackgroundJob::MARCImport - stage a MARC import

This is a subclass of Koha::BackgroundJob.

=head1 API

=head2 Class methods

=head3 job_type

Define the job type of this job: marc_import

=cut

sub job_type {
    return 'marc_import';
}

=head3 process

Process the modification.

=cut

sub process {
    my ( $self, $args ) = @_;

    my $job = Koha::BackgroundJobs->find( $args->{job_id} );
    if ( !exists $args->{job_id} || !$job || $job->status eq 'cancelled' ) {
        return;
    }

    my $job_progress = 0;
    $job->started_on(dt_from_string)
        ->progress($job_progress)
        ->status('started')
        ->store;

    my $dbh = C4::Context->dbh({new => 1});
    $dbh->{AutoCommit} = 0;

    my $params = decode_json $job->data;

    my ( $errors, $marcrecords );
    if( $params->{format} eq 'MARCXML' ) {
        ( $errors, $marcrecords ) = C4::ImportBatch::RecordsFromMARCXMLFile( $params->{file}, $params->{encoding});
    } elsif( $params->{format} eq 'ISO2709' ) {
        ( $errors, $marcrecords ) = C4::ImportBatch::RecordsFromISO2709File( $params->{file}, $params->{record_type}, $params->{encoding} );
    } else { # plugin based
        $errors = [];
        $marcrecords = C4::ImportBatch::RecordsFromMarcPlugin( $params->{file}, $params->{format}, $params->{encoding} );
    }

    my $size = scalar @$marcrecords;
    $size *= 2 if $params->{matcher} ne ""; # if we're matching, job size is doubled
    # $job->job_size( $size )->store;  # this throws an error ("job_size not tested")

    # hm, not sure where/how the old Batching worked? one fork per batch?
    my ( $batch_id, $num_valid, $num_items, @import_errors ) =
      BatchStageMarcRecords(
        $params->{record_type},    $params->{encoding},
        $marcrecords,              $params->{filename},
        $params->{marc_modification_template},
        $params->{comments},       '',
        $params->{parse_items},    0,
        50, sub {  $job->progress( ++$job_progress )->store }
      );
    # ??? last if $job->get_from_storage->status eq 'cancelled';

    if($params->{profile_id}) {
        my $ibatch = Koha::ImportBatches->find($batch_id);
        $ibatch->set({profile_id => $params->{profile_id}})->store;
    }

    my $num_with_matches = 0;
    my $checked_matches = 0;
    my $matcher_failed = 0;
    my $matcher_code = "";
    if ($params->{matcher} ne "") {
        my $matcher = C4::Matcher->fetch($params->{matcher});
        if (defined $matcher) {
            $checked_matches = 1;
            $matcher_code = $matcher->code();
            $num_with_matches =
              BatchFindDuplicates( $batch_id, $matcher, 10, 50,  sub {  $job->progress( ++$job_progress )->store }
            );
            SetImportBatchMatcher($batch_id, $params->{matcher});
            SetImportBatchOverlayAction($batch_id, $params->{overlay_action});
            SetImportBatchNoMatchAction($batch_id, $params->{nomatch_action});
            SetImportBatchItemAction($batch_id, $params->{item_action});
            $dbh->commit();
        } else {
            $matcher_failed = 1;
        }
    } else {
        $dbh->commit();
    }

    my $result = {
        staged          => $num_valid,
        matched         => $num_with_matches,
        num_items       => $num_items,
        import_errors   => scalar(@import_errors),
        total           => $num_valid + scalar(@import_errors),
        checked_matches => $checked_matches,
        matcher_failed  => $matcher_failed,
        matcher_code    => $matcher_code,
        import_batch_id => $batch_id,
        booksellerid    => $params->{booksellerid},
        basketno        => $params->{basketno},
    };

    $params->{result} = $result;

    $job->ended_on(dt_from_string)
        ->data(encode_json $params);

    $job->status('finished') if $job->status ne 'cancelled';
    $job->store;
}

=head3 enqueue

Enqueue the new job

=cut

sub enqueue {
    my ( $self, $args) = @_;

    return unless exists $args->{file};
    #    my @record_ids = @{ $args->{record_ids} };

    $self->SUPER::enqueue({
        job_args => $args,
        job_size => 42, #scalar @{$args->{marcrecords}}
    });
}

1;
