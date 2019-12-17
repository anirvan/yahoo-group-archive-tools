#!perl

use CAM::PDF;
use Date::Format 'time2str';
use Email::MIME;
use Email::Sender::Transport::Mbox;
use File::Temp;
use Getopt::Long 'GetOptions';
use HTML::Entities 'decode_entities';
use IO::All 'io';
use JSON 'decode_json';
use Log::Dispatch;
use Sort::Naturally 'ncmp';
use Text::Levenshtein::XS;
use autodie;
use strict;
use 5.14.0;

my ( $source_path, $destination_path, $uniform_names, $run_pdf,
     $email2pdf_path );

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
                      (e.g. "list.mbox" intead of "my-friends-group.mbox")
                      which can be helpful for mass processing

    --pdf             use email2pdf to generate PDF files (experimental!)
    --email2pdf       location of email2pdf Python script

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
    my $getopt_worked = GetOptions( 'source=s'      => \$source_path,
                                    'destination=s' => \$destination_path,
                                    'uniform-names' => \$uniform_names,
                                    'v|verbose'     => \$verbosity_loud,
                                    'quiet'         => \$verbosity_quiet,
                                    'noisy'         => \$verbosity_loudest,
                                    'help'          => \$do_help,
                                    'pdf'           => \$run_pdf,
                                    'email2pdf=s'   => \$email2pdf_path,
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
        and $destination_dir->is_readable;

    # 4. Get list name

    my $list_name;
    {
        my $about_file = io($source_dir)->catfile( 'about', 'about.json' );
        die "Can't access list description file at $about_file\n"
            unless $about_file->exists
            and $about_file->is_readable;
        my $json  = $about_file->all;
        my $about = decode_json($json);
        $list_name = $about->{name} if $about->{name};
    }

    # 5. Generate uniform names which will be used for files

    my $list_file_name_prefix = 'list';
    if (     !$uniform_names
         and defined $list_name
         and $list_name !~ m/\s/
         and length($list_name) <= 128 ) {
        $list_file_name_prefix = $list_name;
    }

    # 6. Write individual email files

    my $email_count = 0;
    my $email_max   = scalar @email_filenames;
    my @generated_email_files;

    foreach my $email_filename (@email_filenames) {
        $email_count++;

        # 6.1 Open the raw.json file, load the email

        my $email_json       = $email_filename->all;
        my $email_record     = decode_json($email_json);
        my $email_message_id = $email_record->{msgId};
        my $email_topic_id   = $email_record->{topicId};

        # 6.2. Grab info on each attachment from [number].json files

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
                                $attachment_record->{fileId}
                            } = $attachment_record;
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

        # 6.3. Load the email from disk

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

            # 5.4. Fix redacted email headers! Many of the headers
            #      have the email domain names redacted, e.g. a 'From'
            #      header set to "Fred Jones <fred.jones@...>". We
            #      happen to know the user's Yahoo username (e.g.
            #      "fjones123"), so we make a globally unique addr
            #      that doesn't lose what's before the @, and put that
            #      in place to replace the redaction ellipses. We also
            #      add X-Original-Yahoo-Groups-Redacted-* headers to
            #      store the original redacted versions. This process
            #      will likely interfere with verifying DKIM signing!

            foreach my $header_name ( 'From', 'X-Sender', 'Return-Path' ) {
                my $yahoo_id = $email_record->{profile};
                if ($yahoo_id) {
                    my $header_text = eval {
                        local $SIG{__WARN__} = sub { };    # ignore warnings
                        $email->header($header_name);
                    } // '';
                    my $fixed_header_text = $header_text;
                    if ( $fixed_header_text
                        =~ s{@\.\.\.>}{\@$yahoo_id.yahoo.invalid>}g
                        or $fixed_header_text
                        =~ s{^([^<]+@)\.\.\.$}{$1$yahoo_id.yahoo.invalid}g ) {
                        $email->header_set(
                              "X-Original-Yahoo-Groups-Redacted-$header_name",
                              $header_text );
                        $email->header_set( $header_name,
                                            $fixed_header_text );
                    }
                }
            }

            # 6.4. Yahoo Groups API detaches all attachments, so we go
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

                        my $body     = eval { $part->body };
                        my $body_raw = eval { $part->body_raw };
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
                                $part->header_str_set(
                                                  'Content-Transfer-Encoding',
                                                  $original_cte );
                            }
                        }
                    }
                );
            }

            # 6.5. In some cases, there can be attachments that were
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

            # 5.7. Write the RFC822 email to disk

            my $email_destination_dir = $destination_dir->catdir('email');
            $email_destination_dir->mkdir
                unless $email_destination_dir->exists;
            die
                "Can't write to email output directory $email_destination_dir\n"
                unless $email_destination_dir->exists
                and $email_destination_dir->is_readable;

            my $email_file
                = $email_destination_dir->catfile("$email_message_id.eml");
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

    # 7. Write mbox file, consisting of all the RFC822 emails we wrote
    #    to disk. Do this by re-reading the emails from disk, one at a
    #    time, to lower memory usage for large lists.

    my $mbox_destination_dir = $destination_dir->catdir('mbox');
    $mbox_destination_dir->mkdir
        unless $mbox_destination_dir->exists;
    die "Can't write to mbox output directory $mbox_destination_dir\n"
        unless $mbox_destination_dir->exists
        and $mbox_destination_dir->is_readable;

    my $mbox_file
        = $mbox_destination_dir->catfile("$list_file_name_prefix.mbox");
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

    if ($run_pdf) {

        $log->notice(
            qq{[$list_name] Attempting to run experimental email2pdf conversion. If this fails immediately, try running "$email2pdf_path -h" and make sure it returns help text.}
        );

        my $pdf_dir = $destination_dir->catdir('pdf-individual');
        $pdf_dir->mkdir unless $pdf_dir->exists;
        my $combined_pdf_dir = $destination_dir->catdir('pdf-complete');
        $combined_pdf_dir->mkdir unless $combined_pdf_dir->exists;

        my @pdf_files;
        foreach my $email_file (@generated_email_files) {
            my $pdf_filename = $email_file->filename;
            $pdf_filename =~ s/\.eml/.pdf/;
            my $final_pdf_file = $pdf_dir->catfile($pdf_filename);
            build_pdf( $email_file, $final_pdf_file, $list_name );
            if ( $final_pdf_file->exists ) {
                $log->notice("[$list_name] created PDF $final_pdf_file");
                push @pdf_files, $final_pdf_file;
            } else {
                $log->warning(
                    "[$list_name] could not create PDF $final_pdf_file, skipping for now. Feel free to report the exact error message above as a bug report."
                );
            }
        }

    EachPdfFIleToAppend:
        if (@pdf_files) {

            $log->notice(
                qq{[$list_name] Attempting to combine all the PDF files in $pdf_dir into a single PDF file. This might fail if memory is low. Feel free to report this as a bug.}
            );

            my $combined_pdf_file
                = $combined_pdf_dir->catfile("$list_file_name_prefix.pdf");

            my $first_pdf_file      = shift @pdf_files;
            my $combined_pdf_object = CAM::PDF->new( $first_pdf_file->name )
                || {
                $log->warning(
                    "[$list_name] could not create combined PDF file. CAM::PDF error is '$CAM::PDF::errstr'"
                )
                };
            if ($combined_pdf_object) {
                while ( my $pdf_file = shift @pdf_files ) {
                    my $this_pdf_object = CAM::PDF->new( $pdf_file->name )
                        || do {
                        $log->warning(
                            "[$list_name] could not append $pdf_file to combined PDF file, so skipping this email. CAM::PDF error is '$CAM::PDF::errstr'"
                        );
                        next EachPdfFIleToAppend;
                        };
                    $combined_pdf_object->appendPDF($this_pdf_object)
                        || do {
                        $log->warning(
                            "[$list_name] could not append $pdf_file to combined PDF file, so skipping this email. CAM::PDF error is '$CAM::PDF::errstr'"
                        );
                        next EachPdfFIleToAppend;
                        };
                }
            }
            $combined_pdf_object->cleanoutput( $combined_pdf_file->name );
            $log->notice(
                "[$list_name] wrote consolidated PDF file at $combined_pdf_file"
            );
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
    my $pdf_build_dir_path = File::Temp->newdir();
    my $pdf_build_dir      = io($pdf_build_dir_path)->dir;
    $pdf_build_dir->chdir;

    my $temp_pdf_file = $pdf_build_dir->catfile('out.pdf');

    system( $email2pdf_path, '--headers', '-i', $email_file->name,
            '--output-file', $temp_pdf_file->name, '--mostly-hide-warnings' );
    if ( $temp_pdf_file->exists ) {
        $temp_pdf_file->close;
        $final_pdf_file->unlink if $final_pdf_file->exists;
        $temp_pdf_file > $final_pdf_file;
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
            my $time = time2str( "%Y-%M-%d %H:%M:%S", time );
            return "[$time] $args{message}";
        }
    );
}

1;
