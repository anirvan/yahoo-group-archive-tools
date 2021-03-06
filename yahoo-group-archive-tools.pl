#!perl

use CAM::PDF;
use Date::Format 'time2str';
use Email::MIME;
use Email::Sender::Transport::Mbox;
use File::Temp;
use Getopt::Long 'GetOptions';
use HTML::Entities 'decode_entities', 'encode_entities';
use HTML::FormatText::WithLinks::AndTables;
use IO::All 'io';
use IPC::Cmd ();
use JSON 'decode_json';
use List::AllUtils 'natatime';
use Log::Dispatch;
use MCE::Loop;
use MCE::Util;
use Pandoc 'pandoc';
use Sort::Naturally 'ncmp';
use Text::Levenshtein::XS;
use autodie;
binmode STDERR, ':utf8';
binmode STDOUT, ':utf8';
use strict;
use utf8;
use 5.14.0;

my ( $source_path,     $destination_path, $uniform_names,
     $run_pdf,         $email2pdf_path,   $noclobber_pdf,
     $noclobber_email, $use_range_data,   $clobber_out_of_range,
);

my $log = logger();
handle_options();
run();

sub handle_options {

    my $help_text = <<'END';

NAME

    yahoo-group-archive-tools - process output from yahoo-group-archiver

SYNOPSIS

    yahoo-group-archive-tools.pl --source <folder-with-archive> --destination <destination-folder> -v

OPTIONS

    --source          specify root folder of yahoo-group-archiver output
    --destination     specify destination directory, must exist already
                      (generated files will be written in subdirectories)

    --uniform-names   output files should have generic and consistent names
                      (e.g. "list.mbox" intead of "[actual-group-name].mbox")
                      which can be helpful for mass processing

    --pdf             use email2pdf to generate PDF files (experimental!)
    --email2pdf       location of email2pdf Python script
    --noclobber-email do not regenerate an email file if it already exists
    --noclobber-pdf   do not regenerate a PDF file if it already exists
    --range-file      look for an inclusion range file, if present

    --help            print this help message

    --verbose or -v   verbose logging
      or
    --quiet           disable all but critical output

DESCRIPTION

    Takes an archive folder created by the yahoo-group-archiver Python
    script, and converts it into both individual emails, as well as a
    consolidated mbox file.

END

    my $do_help           = 0;
    my $verbosity_loudest = 0;
    my $verbosity_loud    = 0;
    my $verbosity_quiet   = 0;
    my $getopt_worked = GetOptions(
                             'source=s'             => \$source_path,
                             'destination=s'        => \$destination_path,
                             'uniform-names'        => \$uniform_names,
                             'v|verbose'            => \$verbosity_loud,
                             'quiet'                => \$verbosity_quiet,
                             'noisy'                => \$verbosity_loudest,
                             'help'                 => \$do_help,
                             'pdf'                  => \$run_pdf,
                             'email2pdf=s'          => \$email2pdf_path,
                             'noclobber-email'      => \$noclobber_email,
                             'noclobber-pdf'        => \$noclobber_pdf,
                             'range-file'           => \$use_range_data,
                             'clobber-out-of-range' => \$clobber_out_of_range,
    );

    unless ($getopt_worked) {
        die "Error in command line arguments, rerun with --help for help\n";
    }

    if ($verbosity_quiet) {
        $log = logger(3);
    } elsif ($verbosity_loud) {
        $log = logger(1);
    } elsif ($verbosity_loudest) {
        $log = logger(0);
    }

    if ($do_help) {
        say $help_text;
        exit;
    }

    unless ($source_path) {
        die "Need a --source directory, rerun with --help for help\n";

    }

    unless ($destination_path) {
        die "Need a --destination directory, rerun with --help for help\n";

    }

    if ($run_pdf) {
        if ( !$email2pdf_path ) {
            die "No --email2pdf path specified\n";
        } elsif ( !-s $email2pdf_path ) {
            die
                "Can't find the email2pdf Python script at '$email2pdf_path'\n";
        } elsif ( !-x $email2pdf_path ) {
            die
                "The email2pdf script at '$email2pdf_path' should be executable. Make sure it has the right #!python shbang line in line 1.\n";
        }
    } elsif ($email2pdf_path) {
        die
            "You specified an --email2pdf path, but not --pdf. Please rerun with --pdf.\n";
    }

}

sub run {

    # 1. Validate source directories

    my $source_dir = io($source_path)->dir;
    die "Can't access source directory $source_path\n"
        unless $source_dir->exists and $source_dir->is_readable;

    # /email/
    my $email_dir = $source_dir->catdir('email');
    die "Can't access subfolder", $email_dir->name, " sub-folder\n"
        unless $email_dir->exists and $email_dir->is_readable;

    # /attachments/
    my $global_attachments_dir = $source_dir->catdir('attachments');
    unless ( $global_attachments_dir->exists ) {
        undef $global_attachments_dir;
    }

    # /topics/
    my $topics_dir = $source_dir->catdir('topics');
    unless ( $topics_dir->exists ) {
        undef $topics_dir;
    }

    # 2. Try to look for emails

    my @email_filenames = $email_dir->glob('*_raw.json');
    @email_filenames
        = sort { ncmp( $a->filename, $b->filename ) } @email_filenames;
    unless (@email_filenames) {
        die "Couldn't see any *_raw.json in $email_dir";
    }

    # 3. Validate destination dir

    my $destination_dir = io($destination_path)->dir;
    die "Can't access destination directory $destination_path\n"
        unless $destination_dir->exists
        and $destination_dir->is_readable
        and $destination_dir->is_writable;

    # 4. Get list name and description

    my ( $list_name, @list_description_chunks, $about_file );
    {
        $about_file = io($source_dir)->catfile( 'about', 'about.json' );
        unless ( defined $list_name ) {
            if (     $about_file->exists
                 and $about_file->is_readable ) {
                my $json  = $about_file->all;
                my $about = decode_json($json);
                $list_name = $about->{name} if $about->{name};

                # extract description and meta data, clean up as
                # needed, and save as an ordered list of fields,
                # usually in plain text, but sometimes as HTML
                {
                    push @list_description_chunks,
                        { heading => 'Title', text => $about->{title} };

		    if ($about->{website}) {
			push @list_description_chunks,
                            { heading => 'Website', text => $about->{website} };
		    }

                    if ( $about->{description} ) {
                        my $list_description_html = $about->{description};
                        $list_description_html =~ s/^\s+|\s+$//g;
                        $list_description_html
                            =~ s{^<div id="ygrps-yiv-\d+">(.*)</div>$}{<p>$1</p>}sgi;
                        $list_description_html
                            =~ s{<a rel="nofollow" target="_blank"}{<a}sgi;

                        my $attempted_text = eval {
                            local $SIG{__WARN__} = sub { };  # ignore warnings
                            local $SIG{__DIE__}  = sub { };  # ignore dies
                            HTML::FormatText::WithLinks::AndTables->convert(
                                 $list_description_html,
                                 { leftmargin => 0, rightmargin => 1_000_000 }
                            );
                        };

                        push @list_description_chunks,
                            { heading        => 'Description',
                              html           => $list_description_html,
                              text_converted => $attempted_text,
                            };
                    }

                    if ( $about->{trailer} ) {
                        my $trailer__html_encoded = $about->{trailer};
                        my $trailer = decode_entities($trailer__html_encoded);

                        my $trailer_html = $trailer__html_encoded;
			if ($trailer_html =~ m/(^ |  )/m) {
			    $trailer_html =~ s/ /\N{NO-BREAK SPACE}/g;
			}
                        $trailer_html
                            =~ s/(?:\r\n|\r|\n)/<br class="return-to-br">/g;

                        push @list_description_chunks,
                            { heading => 'Trailer',
                              text    => $trailer,
                              html    => $trailer_html,
                            };
                    }

                    my @membership_parts;
                    if (     $about->{memberShipType}
                         and $about->{memberShipType} eq 'RESTRICTED' ) {
                        push @membership_parts,
                            'Subscription requires approval';
                    } elsif (     $about->{memberShipType}
                              and $about->{memberShipType} eq 'OPEN' ) {
                        push @membership_parts, 'Anyone can subscribe';
                    }
                    if (     $about->{messagePost}
                         and $about->{messagePost} eq 'SUBSCRIBERS' ) {
                        push @membership_parts, 'Only subscribers can post';
                    } elsif (     $about->{messagePost}
                              and $about->{messagePost} eq 'ALL' ) {
                        push @membership_parts, 'Anyone can post';
                    }
                    if (     $about->{messagesVis}
                         and $about->{messagesVis} eq 'ALL' ) {
                        push @membership_parts,
                            'Anyone can see archived messages';
                    } elsif (     $about->{messagesVis}
                              and $about->{messagesVis} eq 'SUBSCRIBERS' ) {
                        push @membership_parts,
                            'Only subscribers can see archived messages';
                    }
                    if (@membership_parts) {
                        push @list_description_chunks,
                            {heading => 'Access',
                             text    =>
                                 join( '', map {"* $_\n"} @membership_parts ),
                             html => '<ul>'
                                 . join( "\n",
                                       map {"<li>$_</li>"} @membership_parts )
                                 . '</ul>'
                            };
                    }

                    if ( $about->{name} and $about->{emailDomain} ) {
			push @list_description_chunks,
                            { heading => 'List Email', text => "$about->{name}\@$about->{emailDomain}" };
		    }

                    if ( $about->{webDomain} and $about->{name} ) {
			push @list_description_chunks,
			{ heading => 'List Website', text => "$about->{webDomain}groups/$about->{name}" };
		    }

                    my $category_pretty = $about->{categoryPath};
                    $category_pretty =~ s{^\s*/\s*|\s*/\s*$}{}g;
                    $category_pretty =~ s{\s*/\s*}{ → }g;
                    push @list_description_chunks,
                        { heading => 'Category', text => $category_pretty };
                    push @list_description_chunks,
                        { heading => 'Country', text => $about->{intlCode} };

                    my $created_ymd
                        = time2str( '%Y-%m-%d', $about->{dateCreated} );
                    push @list_description_chunks,
                        { heading => 'Date Created', text => $created_ymd };

                    @list_description_chunks
                        = grep { $_->{html} or $_->{text} }
                        @list_description_chunks;
                }
            }
        }

        my $archive_file = io($source_dir)->catfile('archive.log');
        unless ( defined $list_name ) {
            if ( $archive_file->exists and $archive_file->is_readable ) {
                while ( my $line = $archive_file->getline ) {
                    if ( $line
                         =~ m{/api/v1/groups/([^/\s]+)/(messages|topic)} ) {
                        $list_name = $1;
                        last;
                    }
                }
            }
        }

        unless ( defined $list_name and $list_name =~ m/\w/ ) {
            die
                "Can't seem to find the list name from either $about_file or $archive_file";
        }
    }

    # 5. Generate uniform names which will be used for files

    my $list_file_name_prefix = 'list';
    if (     !$uniform_names
         and defined $list_name
         and $list_name !~ m/\s/
         and length($list_name) <= 128 ) {
        $list_file_name_prefix = $list_name;
    }

    # 6. Get range file, if needed

    my %email_ids_to_use;
    if ($use_range_data) {
        my $meta_dir   = $destination_dir->catdir('meta');
        my $range_file = $meta_dir->catfile('emails_to_process.txt');
        if ( $range_file->exists ) {
            foreach my $line ( $range_file->getlines ) {
                foreach my $number ( $line =~ m/\b(\d+)\b/g ) {
                    $email_ids_to_use{$1} = 1;
                }
            }
        }
    }

    # 7. Write individual email files

    my $email_destination_dir = $destination_dir->catdir('email');
    $email_destination_dir->mkdir unless $email_destination_dir->exists;
    die "Can't write to email output directory $email_destination_dir\n"
        unless $email_destination_dir->exists
        and $email_destination_dir->is_readable;

    my $email_count = 0;
    my $email_max   = scalar @email_filenames;
    my @generated_email_files;
    my $do_we_need_to_create_mbox = 0;

    foreach my $email_filename (@email_filenames) {
        $email_count++;

        # 7.1 Open the raw.json file, load the email

        my ( $email_json,     $email_record, $email_message_id,
             $email_topic_id, $email_file );

        if ( $email_filename->filename =~ m/^(\d+)_raw\.json$/ ) {
            $email_message_id = $1;
            $email_file
                = $email_destination_dir->catfile("$email_message_id.eml");
        }

        # 7.2 If the range file says to skip the email, then we skip,
        #     and delete the file if it already exists

        if ( %email_ids_to_use and !$email_ids_to_use{$email_message_id} ) {
            $log->debug(
                "[$list_name] message $email_message_id: skipping $email_file, which is not in range file ($email_count of $email_max)"
            );
            if ( $email_file->exists and $clobber_out_of_range ) {
                $email_file->unlink;
                $log->info(
                    qq{[$list_name] deleted unwanted/unknown email file $email_file}
                );
                $do_we_need_to_create_mbox = 1;
            }
            next;
        }

        # 7.3. If the email is wanted, reuse the existing file if
        #      noclobber, or get ready to write it

        if (     $noclobber_email
             and $email_file->exists
             and $email_file->size > 0 ) {
            push @generated_email_files, $email_file;
            $log->debug(
                "[$list_name] message $email_message_id: not overwriting existing email at $email_file ($email_count of $email_max)"
            );
            next;
        } else {
            $email_json       = $email_filename->all;
            $email_record     = decode_json($email_json);
            $email_message_id = $email_record->{msgId};
            $email_topic_id   = $email_record->{topicId};
            $email_file
                = $email_destination_dir->catfile("$email_message_id.eml");
        }

        # 7.4. Grab info on each attachment from [number].json files

        # Attachment descriptions (e.g. filename) can live in 3 places:
        # - /email/[email message id].json
        # - /attachments/[attachment id]/attachmentinfo.json
        # - /topics/[email message id].json
        #
        # For now, we try to load the information from either /email/
        # or /topics/

        my %unseen_attachment_file_id_to_details;
        {
            my $email_meta_json_file
                = $email_dir->catfile("$email_message_id.json");
            if ( $email_meta_json_file->exists ) {
                my $email_meta_record
                    = eval { decode_json( $email_meta_json_file->all ) };
                if (     $email_meta_record
                     and $email_meta_record->{attachmentsInfo} ) {
                    foreach my $attachment_record (
                                @{ $email_meta_record->{attachmentsInfo} } ) {
                        if ( $attachment_record->{fileId} ) {
                            $unseen_attachment_file_id_to_details{
                                $attachment_record->{fileId} }
                                = $attachment_record;
                        }
                    }
                }

            } elsif ( $topics_dir and defined $email_topic_id ) {

                my $topic_json_file
                    = $topics_dir->catfile("$email_topic_id.json");
                if ( $topic_json_file->exists ) {
                    my $topic_details
                        = eval { decode_json( $topic_json_file->all ) };
                    if ( $topic_details and $topic_details->{messages} ) {
                        foreach my $message_record (
                                           @{ $topic_details->{messages} } ) {
                            next unless $message_record;
                            next
                                unless $message_record->{msgId}
                                and $message_record->{msgId}
                                == $email_message_id;
                            if ( $message_record->{attachmentsInfo} ) {
                                foreach my $attachment_record (
                                     @{ $message_record->{attachmentsInfo} } )
                                {
                                    if ( $attachment_record->{fileId} ) {
                                        $unseen_attachment_file_id_to_details{
                                            $attachment_record->{fileId}
                                        } = $attachment_record;
                                    }
                                }
                            }
                        }
                    }
                }
            }

        }

        # 7.5. Load the email from the Yahoo API JSON data

        if ( $email_record->{rawEmail} ) {
            my $raw_message = decode_entities( $email_record->{rawEmail} );

            # Not sure why I need to do this, but stripping CRs gets
            # rid of random ^M characters in the header, and appears
            # not to mess with attachments.
            $raw_message =~ s/\r//g;
            $raw_message =~ s/[^[:ascii:]]//g;    # ensure 7 bit safe

            my $email = eval {
                local $SIG{__WARN__} = sub { };    # ignore warnings
                Email::MIME->new($raw_message);
            };

            # Some emails where the very last header line is
            # `X-eGroups-Approved-By:` do NOT have a return between
            # the header and body. This makes for icky broken emails,
            # so we try to fix this. We check to see that the line
            # after the X-eGroups-Approved-By: header is not a
            # standard header line ("Header: "), or a potential
            # continuation line (starts with whitespace), but contains
            # non-blank characters that suggest standard body content.

            if ( $raw_message =~ m/X-eGroups-Approved-By/ ) {
                my $raw_message_maybe_tweaked = $raw_message;

                my $broken_egroups_fix_regexp = qr{

# the first line should be preceded by a return,
# then X-eGroups-Approved-By:,
# followed by non-return chars, then a return char
([\n\r]X-eGroups-Approved-By:\ [^\n\r]+\n)

# Second line could not look like a normal header line.
(?!\w\S*:[ \n\r])

# It should not start with a space or tab
(?![ \t])

# But it should be non-blank
([^\n\r]+(?:[\n\r]|\Z))

		}sx;

                if ( $raw_message_maybe_tweaked
                     =~ s/$broken_egroups_fix_regexp/$1\n$2/ ) {
                    my $email_maybe_tweaked = eval {
                        local $SIG{__WARN__} = sub { };    # ignore warnings
                        Email::MIME->new($raw_message_maybe_tweaked);
                    };
                    if ($email_maybe_tweaked) {
                        $email = $email_maybe_tweaked;
                    }
                }
            }

            # 7.6. Fix redacted email headers! Many of the headers
            #      have the email domain names redacted, e.g. a 'From'
            #      header set to "Fred Jones <fred.jones@...>". We
            #      happen to know either the user's Yahoo profile
            #      (e.g. "fjones123") or user ID (e.g. "123456789"),
            #      so we make a globally unique addr that doesn't lose
            #      what's before the @, and put that in place to
            #      replace the redaction ellipses. We also add
            #      X-Original-Yahoo-Groups-Redacted-* headers to store
            #      the original redacted versions. This process will
            #      likely interfere with verifying DKIM signing!

            foreach my $header_name ( 'From', 'X-Sender', 'Return-Path' ) {
                my $yahoo_identifier
                    = $email_record->{profile} || $email_record->{userId};
                if ($yahoo_identifier) {
                    my $header_text = eval {
                        local $SIG{__WARN__} = sub { };    # ignore warnings
                        $email->header_raw($header_name);
                    } // '';
                    my $fixed_header_text = $header_text;
                    if ( $fixed_header_text
                        =~ s{@\.\.\.>}{\@$yahoo_identifier.yahoo.invalid>}g
                        or $fixed_header_text
                        =~ s{^([^<]+@)\.\.\.$}{$1$yahoo_identifier.yahoo.invalid}g
                    ) {
                        $email->header_set( $header_name,
                                            $fixed_header_text );

                        # found an issue with empty-ish bodies, so skipping
                        if ( ( $email->body_raw // '' ) =~ m/\w/ ) {
                            $email->header_set(
                                "X-Original-Yahoo-Groups-Redacted-$header_name",
                                $header_text
                            );
                        }
                    }
                }
            }

            # 7.7. Yahoo Groups API detaches all attachments, so we go
            #      through all the message parts, try to guess which
            #      attachments go where, and manually reattach them

            # Explanation:
            #
            # Attachment files can live in 3 places on disk,
            # depending on how yahoo-groups-archiver was run:
            # - /email/[email message id]_attachments/[file id]-filename
            # - /attachments/[attachment id]/[file id]-filename
            # - /topics/[email message id]_attachments/[file id]-filename
            #
            # We should assume that every valid attachment is
            # described in one of the attachment description blocks,
            # but that not every attachment exists on disk.

            my %valid_unseen_attachment_by_file_id;
            {
                my @attachment_dirs_to_scan;

                # /email/[email message id]_attachments
                if ($email_dir) {
                    push @attachment_dirs_to_scan,
                        $email_dir->catdir("${email_message_id}_attachments");
                }

                # /topics/[email message id]_attachments
                if ($topics_dir) {
                    push @attachment_dirs_to_scan,
                        $topics_dir->catdir(
                                           "${email_message_id}_attachments");
                    if ( defined $email_topic_id
                         and $email_topic_id ne $email_message_id ) {
                        push @attachment_dirs_to_scan,
                            $topics_dir->catdir(
                                             "${email_topic_id}_attachments");
                    }
                }

                # /attachments/[attachment id]/
                if ($global_attachments_dir) {
                    foreach my $attachment_record (
                              values %unseen_attachment_file_id_to_details ) {
                        if ( $attachment_record->{attachmentId} ) {
                            my $attachment_id
                                = $attachment_record->{attachmentId};
                            if ( $attachment_id =~ m/^\d+$/ ) {
                                push @attachment_dirs_to_scan,
                                    $global_attachments_dir->catdir(
                                                              $attachment_id);
                            }
                        }
                    }
                }

                foreach my $attachments_dir_to_scan (@attachment_dirs_to_scan)
                {
                    next unless $attachments_dir_to_scan->exists;
                    foreach my $attachment_on_disk (
                                             $attachments_dir_to_scan->all ) {
                        my $filename = $attachment_on_disk->filename;
                        if ( $filename =~ m/^(\d+)-/ ) {
                            my $file_id = $1;

                            # If we already have a file on disk for
                            # this attachment file ID, we don't need a
                            # second one. For example, if we know file
                            # ID 1234 can be mapped to the filename
                            # /email/1_attachments/1234-filename.doc
                            # then we don't also need to map it to
                            # /topics/1_attachments/1234-filename.doc
                            next
                                if
                                $valid_unseen_attachment_by_file_id{$file_id};

                            if ( $unseen_attachment_file_id_to_details{
                                     $file_id} ) {
                                my $filename;
                                if ( $unseen_attachment_file_id_to_details{
                                         $file_id}->{filename} ) {
                                    $filename
                                        = $unseen_attachment_file_id_to_details{
                                        $file_id}->{filename};
                                } else {
                                    $filename = $attachment_on_disk->filename;
                                    $filename =~ s/^\d+-//;
                                }

                                if ($filename) {
                                    $valid_unseen_attachment_by_file_id{
                                        $file_id}->{filename} = $filename;
                                    $valid_unseen_attachment_by_file_id{
                                        $file_id}->{details}
                                        = $unseen_attachment_file_id_to_details{
                                        $file_id};
                                    $valid_unseen_attachment_by_file_id{
                                        $file_id}->{file}
                                        = $attachment_on_disk;
                                }
                            }
                        }
                    }
                }
            }

            {
                local $SIG{__WARN__} = sub { };
                $email->walk_parts(
                    sub {
                        my ($part) = @_;
                        local $SIG{__WARN__}
                            = undef;    # can emit lots of warnings
                        return if $part->subparts;

                        my $body         = eval { $part->body };
                        my $body_raw     = eval { $part->body_raw };
                        my $content_type = eval {
                            local $SIG{__WARN__} = sub { };
                            return $part->content_type;
                        };

                        if ( defined $body_raw
                             and $body_raw eq
                             '[ Attachment content not displayed ]' ) {

                            my $attached_the_attachment = 0;

                            my $filename = eval {
                                local $SIG{__WARN__} = sub { };
                                return $part->filename;
                            };

                            if (     defined $filename
                                 and length $filename
                                 and %valid_unseen_attachment_by_file_id ) {
                                my $file_id_to_attach
                                    = find_the_most_likely_attachment_based_on_filename(
                                       $filename,
                                       \%valid_unseen_attachment_by_file_id );
                                if ($file_id_to_attach) {
                                    my $file_to_attach
                                        = $valid_unseen_attachment_by_file_id{
                                        $file_id_to_attach}->{file};

                                    my $attachment_contents
                                        = $file_to_attach->binary->all;
                                    $part->body_set($attachment_contents);
                                    $attached_the_attachment = 1;
                                    $log->debug(
                                        "[$list_name] message $email_message_id: attached file from '$file_to_attach'"
                                    );
                                    delete
                                        $valid_unseen_attachment_by_file_id{
                                        $file_id_to_attach};
                                } else {
                                    my $description_of_remaining_filenames
                                        = '[none]';
                                    my @remaining_filenames;
                                    foreach my $file_record (
                                         values
                                         %valid_unseen_attachment_by_file_id )
                                    {
                                        push @remaining_filenames,
                                            $file_record->{filename};
                                    }
                                    if (@remaining_filenames) {
                                        $description_of_remaining_filenames
                                            = join( ', ',
                                                   map {"'$_'"}
                                                       @remaining_filenames );
                                    }
                                    $log->debug(
                                        "[$list_name] message $email_message_id: we could not map the filename in the email header '$filename' to any of the as-yet unattached attachments listed in the attachments list: $description_of_remaining_filenames"
                                    );
                                }
                            }

                            # Sometimes we just can't find the
                            # attachment file. In that case, we change
                            # the part body to a simple text error
                            # message, and save the originals in
                            # backup headers.

                            unless ($attached_the_attachment) {

                                my $attachment_description = 'attachment';
                                if ($filename) {
                                    $attachment_description
                                        = qq{attachment named '$filename'};
                                } elsif ($content_type) {
                                    $attachment_description
                                        = qq{attachment of type "$content_type"};
                                }

                                $log->warning(
                                    "[$list_name] message $email_message_id: $attachment_description could not be found, skipping"
                                );
                                my $error_message
                                    = qq{The original email contained an $attachment_description but we could not retrieve it via the Yahoo Groups API.};

                                $part->header_str_set(
                                      'X-Original-Content-Type' =>
                                          $part->header_str('Content-Type') );
                                $part->header_str_set(
                                           'X-Original-Content-Disposition' =>
                                               $part->header_str(
                                                        'Content-Disposition')
                                );
                                $part->header_str_set(
                                        'X-Original-Content-Id' =>
                                            $part->header_str('Content-Id') );

                                $part->header_str_set(
                                        'X-Yahoo-Groups-Attachment-Not-Found',
                                        'true' );
                                $part->header_str_set(
                                             'Content-Type' => 'text/plain' );
                                $part->header_str_set('Content-Disposition');
                                $part->header_str_set('Content-ID');
                                $part->content_type_set('text/plain');
                                $part->charset_set('UTF-8');
                                $part->body_str_set($error_message);
                            }
                        } elsif ( defined $body_raw
                                and $body_raw
                                =~ m/\n\(Message over 64 KB, truncated\)$/ ) {
                            my $fixed_body_raw = $body_raw;
                            if ( $fixed_body_raw
                                 =~ s/\n\(Message over 64 KB, truncated\)$// )
                            {
                                $log->warning(
                                    "[$list_name] message $email_message_id: textual content was badly truncated at 64 KB, trying to repair"
                                );
                                $part->header_str_set(
                                           'X-Yahoo-Groups-Content-Truncated',
                                           'true' );

                                # We need to alter the raw body
                                # (before handling encodings), but
                                # Email::MIME is too smart, in that it
                                # prevents us from directly editing
                                # the encoded body. We get around this
                                # by switching it to binary (which
                                # avoids content type smarts), making
                                # the change, then changing back to
                                # the original encoding.
                                my $original_cte = $part->header_str(
                                                 'Content-Transfer-Encoding');
                                $part->header_str_set(
                                                  'Content-Transfer-Encoding',
                                                  'binary' );
                                $part->body_set($fixed_body_raw);
                                if ( defined $original_cte ) {
                                    $part->header_str_set(
                                                  'Content-Transfer-Encoding',
                                                  $original_cte );
                                }
                            }
                        }
                    }
                );
            }

            # 7.8. In some cases, there can be attachments that were
            #      not re-attached because we didn't find a reference
            #      to them in one of the message parts. In those
            #      cases, we go through the list of un-reattached
            #      attachments, and manually add those to the email as
            #      final parts.

            foreach my $remaining_attachment (
                                values %valid_unseen_attachment_by_file_id ) {
                my $new_attachment_part
                    = Email::MIME->create(
                         attributes => {
                             filename    => $remaining_attachment->{filename},
                             disposition => 'attachment',
                             content_type =>
                                 $remaining_attachment->{details}->{fileType},
                         },
                         body => $remaining_attachment->{file}->binary->all,
                    );

                if ($new_attachment_part) {

                    # We ignore warnings because every once in
                    # a while, we'll see encoding errors that
                    # could have been fixed with RFC2047
                    # encoding, but Email::MIME doesn't
                    # support it yet. We could use
                    # Email::MIME::RFC2047, but that doesn't
                    # solve the problem entirely just yet.
                    eval {
                        local $SIG{__WARN__} = sub { };
                        return $email->parts_add( [$new_attachment_part] );
                    };
                    $log->debug(
                        "[$list_name] message $email_message_id: attached file from '$remaining_attachment->{file}' as a standalone top-level attachment"
                    );
                }
            }

            # 7.9. Write the RFC822 email to disk

            $email_file->unlink if $email_file->exists;
            $email_file->print( $email->as_string );
            $email_file->close;
            push @generated_email_files, $email_file;
            $log->info(
                "[$list_name] message $email_message_id: wrote email at $email_file ($email_count of $email_max)"
            );
        }
    }

    $log->notice( "[$list_name] wrote",
                  scalar(@generated_email_files),
                  "email files in $destination_dir/email" );

    # 8. Write mbox file, consisting of all the RFC822 emails we wrote
    #    to disk. Do this by re-reading the emails from disk, one at a
    #    time, to lower memory usage for large lists.

    my $mbox_destination_dir = $destination_dir->catdir('mbox');
    $mbox_destination_dir->mkdir
        unless $mbox_destination_dir->exists;
    die "Can't write to mbox output directory $mbox_destination_dir\n"
        unless $mbox_destination_dir->exists
        and $mbox_destination_dir->is_readable
        and $mbox_destination_dir->is_writable;

    my $mbox_file
        = $mbox_destination_dir->catfile("$list_file_name_prefix.mbox");

    # We need to create a new mbox file if it doesn't exist, or if we
    # wrote any new email files
    if ( !$do_we_need_to_create_mbox ) {
        unless ( $mbox_file and $mbox_file->exists and $mbox_file->size > 0 )
        {
            $do_we_need_to_create_mbox = 1;
        }
    }
    if ( !$do_we_need_to_create_mbox ) {
        my $did_we_create_at_least_one_new_email_file
            = were_any_of_these_files_modified_after_the_script_began(
                                                      @generated_email_files);
        if ($did_we_create_at_least_one_new_email_file) {
            $do_we_need_to_create_mbox = 1;
        }
    }

    if ($do_we_need_to_create_mbox) {
        $mbox_file->unlink;
        my $transport = Email::Sender::Transport::Mbox->new(
                                           { filename => $mbox_file->name } );

        # need to check results after write!
        foreach my $email_file (@generated_email_files) {
            my $rfc822_email = $email_file->binary->all;
            my $results      = $transport->send( $rfc822_email,
                                   { from => 'yahoo-groups-archive-tools' } );
        }
        $log->notice("[$list_name] wrote consolidated mailbox at $mbox_file");
    } else {
        $log->notice(
            "[$list_name] already have a consolidated mailbox at $mbox_file, not regenerating"
        );
    }

    # 9. Create PDF files

    if ($run_pdf) {

        # 9.1 Create individual PDF files

        $log->notice(
            qq{[$list_name] attempting to run experimental email2pdf conversion. If this fails immediately, try running "$email2pdf_path -h" and make sure it returns help text.}
        );

        my $pdf_dir = $destination_dir->catdir('pdf-individual');
        $pdf_dir->mkdir unless $pdf_dir->exists;
        my $combined_pdf_dir = $destination_dir->catdir('pdf-complete');
        $combined_pdf_dir->mkdir unless $combined_pdf_dir->exists;

        my ( @pdf_files, $email_count );
        my $email_max = scalar @generated_email_files;

        # thrice CPUs, but never more than 16
        my $number_of_workers_to_execute;
        {
            $number_of_workers_to_execute = MCE::Util::get_ncpu() * 4;
            if ( $number_of_workers_to_execute > 16 ) {
                $number_of_workers_to_execute = 16;
            }
        }
        MCE::Loop::init { max_workers => $number_of_workers_to_execute,
                          chunk_size  => 5
        };

        my $loop_function = sub {
            my $email_position = shift;
            my $email_file     = $generated_email_files[$email_position];
            my $email_count    = $email_position + 1;
            my $email_id;

            my $pdf_filename = $email_file->filename;
            $pdf_filename =~ s/\.eml/.pdf/;
            if ( $pdf_filename =~ m/^(\d+)/ ) {
                $email_id = $1;
            }
            my $final_pdf_file = $pdf_dir->catfile($pdf_filename);

            unless ($noclobber_pdf) {
                $final_pdf_file->unlink if $final_pdf_file->exists;
            }

            my ( $ok, $warnings_list );
            my $num_build_tries = 0;

            if ( $noclobber_pdf and $final_pdf_file->exists ) {
                $ok            = 1;
                $warnings_list = [];
            }

            # Sometimes the PDF conversion is wonky, so we try doing
            # the conversion up to 3 times.
            for my $attempt ( 1 .. 3 ) {
                last if $ok;
                sleep( $attempt - 1 );
                $num_build_tries++;
                ( $ok, $warnings_list )
                    = build_pdf( $email_file, $final_pdf_file, $list_name );
                last if $ok;
            }

            # Well that didn't work! So as a last ditch effort, we're
            # going to try to simplify the email by grabbing the
            # longest textual content piece(s).

            if ( !$ok ) {
                my $email_raw = eval { io($email_file)->file->binary->all };
                my $email     = eval {
                    local $SIG{__WARN__} = sub { };    # ignore warnings
                    Email::MIME->new($email_raw);
                };

                if ($email) {

                    my @textual_subparts;
                    {
                        my ( @good_textual_subparts,
                             @textual_subparts_to_forcibly_turn_into_plain );

                        $email->walk_parts(
                            sub {
                                my ($part) = @_;
                                local $SIG{__WARN__}
                                    = sub { };    # ignore warnings
                                return if $part->subparts;
                                return
                                    if $part->header_raw(
                                          'X-Yahoo-Groups-Content-Truncated');
                                return
                                    if $part->header_raw(
                                       'X-Yahoo-Groups-Attachment-Not-Found');
                                my $content_type = $part->content_type;
                                if (     $content_type
                                     and $content_type =~ m{^text/}i
                                     and length( $part->body_raw ) >= 10 ) {
                                    if ( $content_type
                                         =~ m{^text/(plain|html)}i ) {
                                        push @good_textual_subparts, $part;
                                    } elsif (
                                         $content_type =~ m{^text/enriched}i )
                                    {
                                        push
                                            @textual_subparts_to_forcibly_turn_into_plain,
                                            $part;
                                    }

                                }
                            }
                        );

                        # We want to focus on the longest text subparts
                        @good_textual_subparts = sort {
                            length( $b->body_str ) cmp length( $a->body_str )
                        } @good_textual_subparts;

                        if ( $good_textual_subparts[0] ) {
                            push @textual_subparts, $good_textual_subparts[0];
                        }
                        if ( $good_textual_subparts[1]
                             and length( $good_textual_subparts[1] )
                             >= length( $good_textual_subparts[1] ) * 0.2 ) {
                            push @textual_subparts, $good_textual_subparts[1];
                        }

                        if ($textual_subparts_to_forcibly_turn_into_plain[0] )
                        {
                            $textual_subparts_to_forcibly_turn_into_plain[0]
                                ->content_type_set('text/plain');
                            push @textual_subparts,
                                $textual_subparts_to_forcibly_turn_into_plain
                                [0];
                        }
                    }

                    unless (@textual_subparts) {
                        if ( $email and $email->body =~ m/\w/ ) {
                            push @textual_subparts, $email;
                        }
                    }

                   # A wide range of possible versions of the email to compare
                    my @email_strings_to_try;

                    # We'll try the subparts straight up
                    foreach my $subpart ( $textual_subparts[0],
                                          $textual_subparts[1] ) {
                        next unless $subpart;
                        eval {
                            local $SIG{__WARN__} = sub { };  # ignore warnings
                            local $SIG{__DIE__}  = sub { };  # ignore dies
                            $email->parts_set( [$subpart] );
                            push @email_strings_to_try, $email->as_string;
                        };
                    }

                    # And we'll try the subparts forcibly re-encoded
                    # to the specified charset
                    foreach my $subpart ( $textual_subparts[0],
                                          $textual_subparts[1] ) {
                        next unless $subpart;
                        eval {
                            local $SIG{__WARN__} = sub { };  # ignore warnings
                            local $SIG{__DIE__}  = sub { };  # ignore dies
                            $subpart->encode_check_set(0);
                            my $body = $subpart->body_str;
                            $subpart->body_str_set($body);
                            $email->parts_set( [$subpart] );
                            push @email_strings_to_try, $email->as_string;
                        };
                    }

                    # And heck, what if we just make a brand new email?
                    # This might help with boundary issues
                    foreach my $subpart ( $textual_subparts[0],
                                          $textual_subparts[1] ) {
                        next unless $subpart;
                        eval {
                            local $SIG{__WARN__} = sub { };  # ignore warnings
                            local $SIG{__DIE__}  = sub { };  # ignore dies

                            my @to      = $email->header_str('To');
                            my @from    = $email->header_str('From');
                            my @date    = $email->header_str('Date');
                            my @subject = $email->header_str('Subject');

                            my $new_email
                                = Email::MIME->create(
                                                   header_str => [
                                                       From    => \@from,
                                                       To      => \@to,
                                                       Date    => $date[0],
                                                       Subject => $subject[0],
                                                   ],
                                                   parts => [$subpart],
                                );

                            push @email_strings_to_try, $new_email->as_string;
                        };
                    }

                    # And we'll try the subparts forcibly ASCII'd
                    foreach my $subpart ( $textual_subparts[0],
                                          $textual_subparts[1] ) {
                        next unless $subpart;
                        eval {
                            local $SIG{__WARN__} = sub { };  # ignore warnings
                            local $SIG{__DIE__}  = sub { };  # ignore dies
                            $subpart->encode_check_set(0);
                            my $body = $subpart->body;
                            $body =~ s/[^[:ascii:]]/ /g;   # ensure 7 bit safe
                            $subpart->charset_set('US-ASCII');
                            $subpart->body_set($body);
                            $email->parts_set( [$subpart] );
                            push @email_strings_to_try, $email->as_string;
                        };
                    }

                    # We'll try manually converting HTML to text
                    foreach my $subpart ( $textual_subparts[0],
                                          $textual_subparts[1] ) {
                        my $content_type
                            = eval { $subpart->content_type } || '';
                        if ( $content_type =~ m{^text/html\b}i ) {
                            my $html_body = $subpart->body;
                            my $text_body = eval {
                                local $SIG{__WARN__}
                                    = sub { };    # ignore warnings
                                local $SIG{__DIE__} = sub { };   # ignore dies
                                HTML::FormatText::WithLinks::AndTables
                                    ->convert($html_body);
                            };
                            if ( defined $text_body
                                 and $text_body =~ m/\w\w\w/ ) {
                                $text_body =~ s/\n\n\n+/\n\n/g;
                                my $new_subpart = eval {
                                    local $SIG{__WARN__}
                                        = sub { };    # ignore warnings
                                    Email::MIME->new( $subpart->as_string );
                                };
                                if ( $new_subpart and ref $new_subpart ) {
                                    $new_subpart->content_type_set(
                                                                'text/plain');
                                    $new_subpart->body_set($text_body);
                                }
                                $email->parts_set( [$new_subpart] );
                                push @email_strings_to_try, $email->as_string;
                            }
                        }
                    }

                    # And this is extreme, but we'll try making the
                    # *entire* email 7-bit. This will mess with emails
                    # where most of the text isn't 7-bit clean.
                    {
                        my $seven_bit_email_raw = $email_raw;
                        $seven_bit_email_raw
                            =~ s/[^[:ascii:]]/ /g;    # ensure 7 bit safe
                        my $seven_bit_email = eval {
                            local $SIG{__WARN__} = sub { };  # ignore warnings
                            Email::MIME->new($seven_bit_email_raw);
                        };
                        if ($seven_bit_email) {
                            push @email_strings_to_try,
                                $seven_bit_email->as_string;
                        }
                    }

                    if (@email_strings_to_try) {
                        $log->debug(
                            "[$list_name] PDF $email_count: conversion wasn't working, so we're trying to simplify it"
                        );

                        my %email_strings_seen;

                    EachEmailToTry:
                        foreach
                            my $email_string_to_try (@email_strings_to_try) {
                            next if $email_strings_seen{$email_string_to_try};
                            $email_strings_seen{$email_string_to_try} = 1;
                            my $temp_email_fh
                                = File::Temp->new( UNLINK => 1 );
                            my $temp_simplified_email_file
                                = io( $temp_email_fh->filename );
                            $temp_simplified_email_file->print(
                                                        $email_string_to_try);
                            $num_build_tries++;
                            ( $ok, $warnings_list )
                                = build_pdf( $temp_simplified_email_file,
                                             $final_pdf_file, $list_name );
                            $temp_simplified_email_file->unlink;

                            if ($ok) {
                                last EachEmailToTry;
                            } else {
                                sleep( 1 + rand(2) );
                                next EachEmailToTry;
                            }
                        }
                    }
                }
            }

            my @pdf_build_warnings = @{$warnings_list};

            foreach my $warning (@pdf_build_warnings) {
                $log->debug(
                    "[$list_name] PDF $email_count: issue while generating PDF $final_pdf_file: '$warning'"
                );
            }

            if ( $ok and $final_pdf_file->exists ) {
                if ( $num_build_tries == 0 and $noclobber_pdf ) {
                    $log->debug(
                        "[$list_name] PDF $email_id: reusing existing PDF ${final_pdf_file} ($email_count of $email_max)"
                    );
                } else {
                    my $tries_text = '';
                    if ( $num_build_tries != 1 ) {
                        $tries_text = " after $num_build_tries tries";
                    }
                    $log->info(
                        "[$list_name] PDF $email_id: created PDF ${final_pdf_file}${tries_text} ($email_count of $email_max)"
                    );
                }
                MCE->gather( $final_pdf_file->name );
            } else {
                $log->warning(
                    "[$list_name] PDF $email_id: could not create PDF $final_pdf_file based on $email_file even after $num_build_tries tries ($email_count of $email_max), skipping for now."
                );

                if ( !$log->would_log('debug') and @pdf_build_warnings ) {
                    $log->warning(
                        "[$list_name] PDF $email_id: FYI, the following are some of the errors/warnings encountered during the failed PDF generation. If you see a consistent issue, feel free to report the exact error message above as a bug report."
                    );
                    foreach my $warning (@pdf_build_warnings) {
                        $log->warning(
                            "[$list_name] PDF $email_id: issue while generating PDF $final_pdf_file: '$warning'"
                        );
                    }
                }

            }

        };
        my @pdf_file_paths = mce_loop_s {
            my ( $mce, $chunk_ref, $chunk_id ) = @_;
            for my $item ( @{$chunk_ref} ) {
                $loop_function->($item);
            }
        }
        0, $#generated_email_files;

        @pdf_file_paths = grep {$_} @pdf_file_paths;
        @pdf_file_paths = sort { ncmp( $a, $b ) } @pdf_file_paths;

        # 9.2 Create merged PDF file

        @pdf_files = map { io($_)->file } @pdf_file_paths;
        my $combined_pdf_file
            = $combined_pdf_dir->catfile("$list_file_name_prefix.pdf");

        # Create new combined if we have PDF files to combine.
        # But if we're in noclobber mode, do it if and only if we
        #   actually wrote some new PDF files.
        my $do_we_need_to_create_combined_pdf = 0;

        if ($clobber_out_of_range) {
            my %pdf_file_paths_on_disk;
            foreach my $pdf_file_on_disk ( $pdf_dir->all ) {
                $pdf_file_paths_on_disk{ $pdf_file_on_disk->name } = 1;
            }
            foreach my $wanted_pdf_file_path (@pdf_file_paths) {
                delete $pdf_file_paths_on_disk{$wanted_pdf_file_path};
            }
            foreach my $file_path ( keys %pdf_file_paths_on_disk ) {
                my $unwanted_file = io($file_path)->file;
                if ( $unwanted_file->exists ) {
                    $log->info(
                        qq{[$list_name] deleted unwanted/unknown PDF file $unwanted_file}
                    );
                }
                $do_we_need_to_create_combined_pdf = 1;
            }
        }

        if ( !$do_we_need_to_create_combined_pdf and @pdf_files ) {
            $do_we_need_to_create_combined_pdf = 1;
            if ( $noclobber_pdf and $combined_pdf_file->exists ) {
                my $did_we_create_at_least_one_new_pdf_file
                    = were_any_of_these_files_modified_after_the_script_began(
                                                                  @pdf_files);
                if ( !$did_we_create_at_least_one_new_pdf_file ) {
                    $do_we_need_to_create_combined_pdf = 0;
                    $log->notice(
                        qq{[$list_name] no need to combine PDF files in $pdf_dir since it's already there}
                    );
                }
            }
        }

        if ($do_we_need_to_create_combined_pdf) {

            my $num_pdfs_to_combine = scalar @pdf_file_paths;
            my $memory_warning      = '';
            if ( $num_pdfs_to_combine > 100 ) {
                $memory_warning
                    = ' This might fail if memory is low. Feel free to report this as a bug.';
            }
            $log->notice(
                qq{[$list_name] attempting to combine all $num_pdfs_to_combine PDF files in $pdf_dir into a single PDF file.$memory_warning}
            );

            my $do_we_have_qpdf_installed = do_we_have_qpdf_installed();

            eval {

                # CAM::PDF is memory intensive, so we use it only up
                # to a certain point, before falling back to qpdf
                my $maximum_count_of_pdfs_before_we_fall_back_to_qpdf = 250;
                if (     $do_we_have_qpdf_installed
                     and @pdf_files
                     > $maximum_count_of_pdfs_before_we_fall_back_to_qpdf ) {
                    $log->debug(
                        "[$list_name] using qpdf instead of CAM::PDF as PDF combining method"
                    );
                    return;
                }

                my @pdf_files_to_combine = @pdf_files;
                my $first_pdf_file       = shift @pdf_files_to_combine;
                my $combined_pdf_object
                    = CAM::PDF->new( $first_pdf_file->name )
                    || {
                    $log->error(
                        "[$list_name] could not create combined PDF file. CAM::PDF error is '$CAM::PDF::errstr'"
                    )
                    };

                if ($combined_pdf_object) {

                EachPdfFileToAppend:
                    while ( my $pdf_file = shift @pdf_files_to_combine ) {
                        my $this_pdf_object = CAM::PDF->new( $pdf_file->name )
                            || do {
                            $log->warning(
                                "[$list_name] could not append $pdf_file to combined PDF file, so skipping this email. CAM::PDF error is '$CAM::PDF::errstr'"
                            );
                            next EachPdfFileToAppend;
                            };
                        $combined_pdf_object->appendPDF($this_pdf_object)
                            || do {
                            $log->warning(
                                "[$list_name] could not append $pdf_file to combined PDF file, so skipping this email. CAM::PDF error is '$CAM::PDF::errstr'"
                            );
                            next EachPdfFileToAppend;
                            };
                    }
                }
                $combined_pdf_object->cleanoutput( $combined_pdf_file->name );
            };

            if ( $combined_pdf_file->exists and $combined_pdf_file->size ) {
                $log->notice(
                    "[$list_name] wrote consolidated PDF file at $combined_pdf_file"
                );
            } else {
                $combined_pdf_file->unlink if $combined_pdf_file->exists;

                if ($do_we_have_qpdf_installed) {
                    $log->info(
                        "[$list_name] using qpdf to write consolidated PDF file at $combined_pdf_file"
                    );

                    # qpdf can combine multiple PDFs into a
                    # single final PDF. We're going to take batches of
                    # PDF, and save them as roll-ups. Finally, we'll
                    # merge all the roll-ups as needed.

                    my $combined_pdf_build_dir_path
                        = File::Temp->newdir(
                             'yahoo-groups-archive-tools-pdf-qpdf-XXXXXXXXXX',
                             TMPDIR => 1 );
                    my $combined_pdf_build_dir
                        = io($combined_pdf_build_dir_path)->dir;
                    $combined_pdf_build_dir->chdir;

                    my $it = natatime 1000, @pdf_files;
                    my @rollup_pdf_files;

                    my $pdfs_set_id = 0;
                    my $got_error   = 0;
                EachPdfSet:
                    while ( my @pdf_files_to_merge = $it->() ) {
                        $pdfs_set_id++;
                        my $output_file
                            = io("rollup_${pdfs_set_id}.pdf")->file;
                        my ( $merged_ok, $merge_error_message )
                            = merge_pdf_files_using_qpdf( $output_file,
                                                        @pdf_files_to_merge );
                        if ($merged_ok) {
                            push @rollup_pdf_files, $output_file;
                        } else {
                            $got_error = 1;
                            $log->error(
                                "[$list_name] ERROR: failed to write qpdf-based PDF file, round 1.$pdfs_set_id. Reason is: $merge_error_message"
                            );
                        }
                    }
                    if ( !$got_error and @rollup_pdf_files ) {
                        my $output_file;
                        if ( scalar @rollup_pdf_files == 1 ) {
                            $output_file = $rollup_pdf_files[0];
                        } else {
                            $output_file = io('final.pdf')->file;

                            my ( $merged_ok, $merge_error_message )
                                = merge_pdf_files_using_qpdf( $output_file,
                                                          @rollup_pdf_files );
                            unless ($merged_ok) {
                                $log->error(
                                    "[$list_name] ERROR: failed to write qpdf-based PDF file, round 2. Reason is '$merge_error_message'"
                                );
                                $got_error = 1;
                            }
                        }
                        if ( !$got_error and $output_file->exists ) {
                            $output_file > $combined_pdf_file;
                            if ( $combined_pdf_file->exists ) {
                                $log->notice(
                                    "[$list_name] wrote consolidated PDF file at $combined_pdf_file (fell back to using qpdf)"
                                );
                            }
                        }
                    }

                } else {
                    $log->error(
                        "[$list_name] ERROR: failed to write consolidated PDF file at $combined_pdf_file, and we can't fall back to qpdf"
                    );
                }
            }
        }

    }

    # 10. Create about metadata files
    {
        my $about_destination_dir = $destination_dir->catdir('about');
        $about_destination_dir->rmtree if $about_destination_dir->exists;
        $about_destination_dir->mkdir;
        die "Can't write to email output directory $about_destination_dir\n"
            unless $about_destination_dir->exists
            and $about_destination_dir->is_readable;

        if ( $about_file->exists ) {
            my $about_json_file = $about_destination_dir->catfile(
                                                'about [original json].json');
            $about_json_file->unlink if $about_json_file->exists;
            $about_file->copy( $about_json_file->name );
        }

        # save as HTML, and Markdown if at all possible
        {
            my $html = '';
            foreach my $chunk (@list_description_chunks) {
                $html
                    .= '<h2>'
                    . HTML::Entities::encode_entities( $chunk->{heading} )
                    . '</h2>' . "\n\n";
                if ( $chunk->{html} ) {
                    my $html_chunk_cleaned_up = $chunk->{html};
                    $html_chunk_cleaned_up
                        =~ s/<br class="return-to-br">/<br>/g;
                    $html .= '<div>' . $html_chunk_cleaned_up . "</div>\n\n";
                } elsif ( $chunk->{text} ) {
                    $html
                        .= '<div>'
                        . HTML::Entities::encode_entities( $chunk->{text} )
                        . "</div>\n\n";
                }
            }

            my $about_html_file = $about_destination_dir->catfile(
                                             'about [raw html snippet].html');
            $about_html_file->unlink if $about_html_file->exists;
            $about_html_file->utf8->print($html);
            $about_html_file->close;

            if ( do_we_have_pandoc_installed() ) {
                my $markdown        = '';
                my $html_cleaned_up = $html;
                $html_cleaned_up =~ s/<br>/\n/g;
                $html_cleaned_up =~ s/<br class="return-to-br">/<br>/g;
                my $pandoc_ok = eval {
                    pandoc( -f          => 'html',
                            -t          => 'markdown_strict',
                            '--columns' => 1_000_000,
                            { in => \$html_cleaned_up, out => \$markdown }
                    ) ? 0 : 1;
                };

                if ( $pandoc_ok and $markdown ) {
                    $markdown =~ s/\\_/_/g;
                    my $about_markdown_file = $about_destination_dir->catfile(
                                                     'about [markdown].text');
                    $about_markdown_file->unlink
                        if $about_markdown_file->exists;
                    $about_markdown_file->print($markdown);
                    $about_markdown_file->close;
                }
            }

        }

        # save as text
        {
            my $text = '';
            foreach my $chunk (@list_description_chunks) {
                $text .= "\U$chunk->{heading}:\n\n";
                $text .= ( $chunk->{text} || $chunk->{text_converted} )
                    . "\n\n";
            }
            $text =~ s/\n\n\n+/\n\n/g;

            my $about_text_file = $about_destination_dir->catfile(
                                             'about [unstructured text].txt');
            $about_text_file->unlink if $about_text_file->exists;
            $about_text_file->utf8->print($text);
            $about_text_file->close;
        }

    }

    return;
}

sub find_the_most_likely_attachment_based_on_filename {
    my ( $wanted_filename, $unseen_present_attachment_files_by_file_id ) = @_;

    return unless defined $wanted_filename;
    return unless length $wanted_filename;

    my $normalized_wanted_filename = $wanted_filename;
    $normalized_wanted_filename =~ s/\s+/-/g;

    my %name_to_file;
    foreach
        my $file_id ( keys %{$unseen_present_attachment_files_by_file_id} ) {
        my $filename = $unseen_present_attachment_files_by_file_id->{$file_id}
            ->{filename};
        $filename =~ s/&#39;/'/g;   # only URI escape seen, being conservative
        $name_to_file{$filename}->{file_id} = $file_id;
    }

    foreach my $filename ( keys %name_to_file ) {
        if ( $wanted_filename eq $filename ) {
            $name_to_file{$filename}->{distance} = 0;
        } elsif ( $normalized_wanted_filename eq $filename ) {
            $name_to_file{$filename}->{distance} = 0.01;
        } else {
            $name_to_file{$filename}->{distance}
                = Text::Levenshtein::XS::distance($normalized_wanted_filename,
                                                  $filename ) /
                length($filename);
        }
    }

    my @attachments_by_distance = sort {
        ( $name_to_file{$a}->{distance} // 1 )
            <=> ( $name_to_file{$b}->{distance} // 1 )
    } values %name_to_file;

    if (     @attachments_by_distance
         and $attachments_by_distance[0]->{distance} <= 0.8 ) {
        return $attachments_by_distance[0]->{file_id};
    }

    return;
}

sub build_pdf {
    my ( $email_file, $final_pdf_file, $list_name ) = @_;

    # make temp dir
    my $pdf_build_dir_path =
        File::Temp->newdir( 'yahoo-groups-archive-tools-pdf-XXXXXXXXXX',
                            TMPDIR => 1 );
    my $pdf_build_dir = io($pdf_build_dir_path)->dir;
    $pdf_build_dir->chdir;

    my $temp_pdf_file = $pdf_build_dir->catfile('out.pdf');

    my ( $ok, @warnings );

    my @system_args = (
               $email2pdf_path, '--headers', '-i', $email_file->name,
               '--output-file', $temp_pdf_file->name, '--mostly-hide-warnings'
    );

    my ( $cmd_success,    $cmd_error_message, $cmd_full_buf,
         $cmd_stdout_buf, $stderr_array
    ) = IPC::Cmd::run( command => \@system_args, timeout => 60 );

    if ( $stderr_array and @{$stderr_array} ) {
        push @warnings, @{$stderr_array};
    }

    if (     $cmd_success
         and $temp_pdf_file->exists
         and $temp_pdf_file->size > 0 ) {
        $temp_pdf_file->close;
        $final_pdf_file->unlink if $final_pdf_file->exists;
        $temp_pdf_file > $final_pdf_file;
        $ok = 1;
    }

    my $maybe_error_file
        = $pdf_build_dir->catfile('out_warnings_and_errors.txt');
    if ( $maybe_error_file->exists ) {
        @warnings = $maybe_error_file->getlines;
        @warnings = grep {m/\w/} @warnings;
        @warnings = map  { chomp; s/[\s\r\n]+/ /g; $_ } @warnings;
    }

    return ( $ok, \@warnings );
}

sub merge_pdf_files_using_qpdf {
    my ( $output_file, @files_to_merge ) = @_;
    $output_file->unlink if $output_file->exists;

    my @command = ( 'qpdf', '--empty', '--pages',
                    ( map { $_->name } @files_to_merge ),
                    '--', $output_file
    );
    my ( $cmd_success,    $cmd_error_message, $cmd_full_buf,
         $cmd_stdout_buf, $stderr_array )
        = IPC::Cmd::run( command => \@command,
                         timeout => 20_000 );

    my $error_message = '';
    if ( $cmd_success and $output_file->exists and $output_file->size > 0 ) {
        return ( 1, $error_message );
    } else {
        my @error_message_parts = ( $cmd_error_message || 'unknown error' );
        if ( $cmd_full_buf and @{$cmd_full_buf} ) {
            push @error_message_parts, @{$cmd_full_buf};
        }
        @error_message_parts
            = map { s/^\s+|\s+$//g; $_ } @error_message_parts;
        return ( 0, join( '; ', @error_message_parts ) );
    }
}

sub do_we_have_qpdf_installed {
    state $do_we_have_qpdf_installed = IPC::Cmd::can_run('qpdf');
    return $do_we_have_qpdf_installed;
}

sub do_we_have_pandoc_installed {
    state $do_we_have_pandoc_installed = IPC::Cmd::can_run('pandoc');
    return $do_we_have_pandoc_installed;
}

# takes one or more IO::All files
# returns true if any of them were modified after the script started
sub were_any_of_these_files_modified_after_the_script_began {
    my @files             = @_;
    my $script_start_time = $^T;
    foreach my $file (@files) {
        my $time_last_modified = $file->mtime;
        if ( $time_last_modified > $script_start_time ) {
            return 1;
        }
    }
    return;
}

sub logger {
    my $min_log_level = shift // 2;
    return Log::Dispatch->new(
        outputs =>
            [ [ 'Screen', min_level => $min_log_level, newline => 1 ] ],
        callbacks => sub {
            my %args = @_;
            my $time = time2str( "%Y-%m-%d %H:%M:%S", time );
            return "[$time] $args{message}";
        }
    );
}

1;
