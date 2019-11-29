#!perl

use Email::MIME;
use Email::Sender::Transport::Mbox;
use Getopt::Long 'GetOptions';
use HTML::Entities 'decode_entities';
use IO::All 'io';
use JSON 'decode_json';
use Sort::Naturally 'ncmp';
use Text::Levenshtein::XS;
use autodie;
use strict;
use 5.14.0;

my ( $source_path, $destination_path, $verbose );

handle_options();
run();

sub handle_options {

    my $help_text = <<'END';

NAME

    yahoo-group-archive-tools - process output from yahoo-group-archiver

SYNOPSIS

    yahoo-group-archive-tools.pl --source <folder-with-archive> --destination <destination-folder>

OPTIONS

    --help Print this help message

DESCRIPTION

    Takes an archive folder created by the yahoo-group-archiver Python
    script, and convert it into both individual emails, as well as a
    consolidated mbox file. These can be used for followup processing.

END

    my $get_help;
    my $getopt_worked = GetOptions( 'source=s'      => \$source_path,
                                    'destination=s' => \$destination_path,
                                    'verbose'       => \$verbose,
                                    'help'          => \$get_help
    );

    unless ($getopt_worked) {
        die "Error in command line arguments, rerun with -h for help\n";
    }

    unless ($source_path) {
        die "Need a --source directory, rerun with -h for help\n";

    }

    unless ($destination_path) {
        die "Need a --destination directory, rerun with -h for help\n";

    }

    if ($get_help) {
        say $help_text;
        exit;
    }

}

sub run {

    # 1. Validate source dir

    my $source_dir = io($source_path)->dir;
    die "Can't access source directory $source_path\n"
        unless $source_dir->exists and $source_dir->is_readable;

    my $email_dir = $source_dir->catdir('email');
    die "Can't access subfolder", $email_dir->name, " sub-folder\n"
        unless $email_dir->exists and $email_dir->is_readable;

    # 2. Validate emails dir

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

    # 4. Validate list about data

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

    # 5. Write individual email files

    my $email_count = 0;
    my $email_max   = scalar @email_filenames;
    my @generated_email_files;

    foreach my $email_filename (@email_filenames) {
        $email_count++;

        # 5.1 Open the raw.json file, load the email

        my $email_json       = $email_filename->all;
        my $email_record     = decode_json($email_json);
        my $email_message_id = $email_record->{msgId};

        # 5.2. Grab info on each attachment from [number].json files

        my ( $sender_yahoo_id, %unseen_attachment_id_to_details );
        {
            my $email_meta_json_path = $email_filename->filename;
            $email_meta_json_path =~ s/_raw\.json/.json/;
            my $email_meta_file = io( $email_filename->filepath )
                ->catfile($email_meta_json_path);
            if ( $email_meta_file->exists and $email_meta_file->is_readable )
            {
                my $email_meta_json = $email_meta_file->all;
                my $email_meta_record
                    = eval { decode_json($email_meta_json) } || {};
                if (     $email_meta_record
                     and $email_meta_record->{attachmentsInfo} ) {
                    foreach my $attachment_record (
                                @{ $email_meta_record->{attachmentsInfo} } ) {
                        if ( $attachment_record->{fileId} ) {
                            $unseen_attachment_id_to_details{
                                $attachment_record->{fileId}
                            } = $attachment_record;
                        }
                    }
                }
            }
        }

        # 5.3. Load the email from disk

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
            #      may interfere with verifying DKIM signing!

            foreach my $header_name ( 'From', 'X-Sender', 'Return-Path' ) {
                my $yahoo_id = $email_record->{profile};
                if ($yahoo_id) {
                    my $header_text       = $email->header($header_name);
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

            # 5.5. Yahoo Groups API detaches all attachments, so we go
            #      through all the message parts, try to guess which
            #      attachments go where, and manually reattach them

            my $attachments_dir_path = $email_filename->filename;
            $attachments_dir_path =~ s/_raw\.json$/_attachments/;
            my $attachments_dir
                = io( $email_filename->filepath )
                ->catdir($attachments_dir_path);

            if ( $attachments_dir->exists and $attachments_dir->is_readable )
            {
                local $SIG{__WARN__} = sub { };
                $email->walk_parts(
                    sub {
                        my ($part) = @_;
                        local $SIG{__WARN__}
                            = undef;    # can emit lots of warnings
                        return if $part->subparts;
                        my $body = eval { $part->body };
                        if ( defined $body
                             and $body eq
                             '[ Attachment content not displayed ]' ) {

                            my $filename = eval {
                                local $SIG{__WARN__} = sub { };
                                $part->filename;
                            };
                            if ( defined $filename and length $filename ) {
                                my $attachment_file_on_disk
                                    = find_the_most_likely_attachment_in_directory(
                                                           $filename,
                                                           $attachments_dir );
                                if ($attachment_file_on_disk) {
                                    my $attachment_contents
                                        = $attachment_file_on_disk->binary
                                        ->all;

                                    $part->body_set($attachment_contents);
                                    if ( $attachment_file_on_disk->filename
                                         =~ m/^(\d+)-./ ) {
                                        my $attachment_id = $1;
                                        delete
                                            $unseen_attachment_id_to_details{
                                            $attachment_id};
                                    }
                                }
                            }
                        }
                    }
                );
            }

            # 5.6. In some cases, there can be attachments that were
            #      not re-attached because we didn't find a reference
            #      to them in one of the message parts. In those
            #      cases, we go through the list of un-reattached
            #      attachments, and manually add those to the email as
            #      final parts.

            foreach my $remaining_attachment (
                                   values %unseen_attachment_id_to_details ) {
                if ( defined $remaining_attachment->{filename} ) {
                    my $attachment_file_on_disk
                        = find_the_most_likely_attachment_in_directory(
                                            $remaining_attachment->{filename},
                                            $attachments_dir );
                    if ($attachment_file_on_disk) {
                        my $new_attachment_part
                            = Email::MIME->create(
                            attributes => {
                                filename => $remaining_attachment->{filename},
                                disposition => "attachment",
                                content_type =>
                                    $remaining_attachment->{fileType},
                            },
                            body => $attachment_file_on_disk->binary->all,
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
                                $email->parts_add( [$new_attachment_part] );
                            };
                        }
                    }
                }
            }

            # 5.7. Write the RFC822 email to disk

            my $email_file = $destination_dir->file("$email_message_id.eml");
            $email_file->unlink;
            $email_file->print( $email->as_string );
            $email_file->close;
            push @generated_email_files, $email_file;
            say
                "[$list_name] wrote $email_count of $email_max, at $email_file"
                if $verbose;
        }
    }

    # 6. Write mbox file, consisting of all the RFC822 emails we wrote
    #    to disk. Do this by re-reading the emails from disk, one at a
    #    time, to lower memory usage for large lists.

    my $mbox_file = $destination_dir->file("list.mbox");
    $mbox_file->unlink;
    my $transport = Email::Sender::Transport::Mbox->new(
                                           { filename => $mbox_file->name } );

    # need to check results after write!
    foreach my $email_file (@generated_email_files) {
        my $rfc822_email = $email_file->binary->all;
        my $results      = $transport->send( $rfc822_email,
                                   { from => 'yahoo-groups-archive-tools' } );
    }
    say "[$list_name] wrote consolidated mailbox at $mbox_file"
        if $verbose;
    return;
}

sub find_the_most_likely_attachment_in_directory {
    my ( $wanted_filename, $attachments_dir ) = @_;

    return unless defined $wanted_filename;
    return unless length $wanted_filename;

    my $normalized_wanted_filename = $wanted_filename;
    $normalized_wanted_filename =~ s/\s+/-/g;

    my %name_to_file;
    foreach my $attachment_on_disk ( $attachments_dir->all ) {
        my $filename = $attachment_on_disk->filename;
        $filename =~ s/^\d+-//;
        $name_to_file{$filename}->{file} = $attachment_on_disk;
    }

    foreach my $potential_attachment_on_disk_filename ( keys %name_to_file ) {
        my $distance =
            Text::Levenshtein::XS::distance( $normalized_wanted_filename,
                                     $potential_attachment_on_disk_filename );
        $name_to_file{$potential_attachment_on_disk_filename}->{distance}
            = $distance / length($normalized_wanted_filename);
    }

    my @attachments_by_distance
        = sort { $a->{distance} <=> $b->{distance} } values %name_to_file;

    if (     @attachments_by_distance
         and $attachments_by_distance[0]->{distance} <= 0.8 ) {
        return $attachments_by_distance[0]->{file};
    }

    return;
}
