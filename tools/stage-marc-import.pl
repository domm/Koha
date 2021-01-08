#!/usr/bin/perl

# Script for handling import of MARC data into Koha db
#   and Z39.50 lookups

# Koha library project  www.koha-community.org

# Licensed under the GPL

# Copyright 2000-2002 Katipo Communications
#
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

# standard or CPAN modules used
use CGI qw ( -utf8 );
use CGI::Cookie;
use MARC::File::USMARC;
use JSON qw( encode_json );

# Koha modules used
use C4::Context;
use C4::Auth;
use C4::Output;
use C4::Biblio;
use C4::Matcher;
use Koha::UploadedFiles;
use C4::MarcModificationTemplates;
use Koha::Plugins;
use Koha::ImportBatches;
use Koha::BackgroundJob::MARCImport;

my $input = CGI->new;

my %params = map { $_ => scalar $input->param($_) } qw(uploadedfileid matcher overlay_action nomatch_action parse_items item_action comments record_type encoding format marc_modification_template_id basketno booksellerid profile_id);
$params{encoding} ||= 'UTF-8';
$params{format}   ||=  'ISO2709';
my $fileID = $params{uploadedfileid};

my ( $template, $loggedinuser, $cookie ) = get_template_and_user(
    {
        template_name   => "tools/stage-marc-import.tt",
        query           => $input,
        type            => "intranet",
        flagsrequired   => { tools => 'stage_marc_import' },
        debug           => 1,
    }
);

$template->param(
    SCRIPT_NAME  => '/cgi-bin/koha/tools/stage-marc-import.pl',
    uploadmarc   => $fileID,
    record_type  => $params{record_type},
    basketno     => $params{basketno},
    booksellerid => $params{booksellerid},
);

if ($fileID) {
    my $upload = Koha::UploadedFiles->find( $fileID );
    $params{file} = $upload->full_path;
    $params{filename} = $upload->filename;

    #warn "$filename: " . ( join ',', @$errors ) if @$errors;

    my $job_id = Koha::BackgroundJob::MARCImport->new->enqueue(\%params);
    if ($job_id) {
        $template->param(
            view => 'enqueued',
            job_id => $job_id,
        );
    }
    else {
        # push @messages, {
        #     type => 'error',
        #     code => 'cannot_enqueue_job',
        #     error => "no job id ??",
        # };
        $template->param( view => 'errors' );
    }

         # domm - not sure abnout this	    $template->param(staged => $num_valid,
         # domm - not sure abnout this 	                     matched => $num_with_matches,
         # domm - not sure abnout this                         num_items => $num_items,
         # domm - not sure abnout this                         import_errors => scalar(@import_errors),
         # domm - not sure abnout this                         total => $num_valid + scalar(@import_errors),
         # domm - not sure abnout this                         checked_matches => $checked_matches,
         # domm - not sure abnout this                         matcher_failed => $matcher_failed,
         # domm - not sure abnout this                         matcher_code => $matcher_code,
         # domm - not sure abnout this                         import_batch_id => $batch_id,
         # domm - not sure abnout this                         booksellerid => $booksellerid,
         # domm - not sure abnout this                         basketno => $basketno
         # domm - not sure abnout this                        );
         # domm - not sure abnout this    }

} else {
    # initial form
    if ( C4::Context->preference("marcflavour") eq "UNIMARC" ) {
        $template->param( "UNIMARC" => 1 );
    }
    my @matchers = C4::Matcher::GetMatcherList();
    $template->param( available_matchers => \@matchers );

    my @templates = GetModificationTemplates();
    $template->param( MarcModificationTemplatesLoop => \@templates );

    if ( C4::Context->config('enable_plugins') ) {

        my @plugins = Koha::Plugins->new()->GetPlugins({
            method => 'to_marc',
        });
        $template->param( plugins => \@plugins );
    }
}

output_html_with_http_headers $input, $cookie, $template->output;

exit 0;


