#!perl

use Email::MIME;
use Getopt::Long 'GetOptions';
use HTML::Entities 'decode_entities';
use IO::All 'io';
use JSON 'decode_json';
use Sort::Naturally 'ncmp';
use Text::Levenshtein::XS;
use autodie;
use strict;
use 5.14.0;
binmode( STDOUT, ":utf8" );

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
        my $json  = $about_file->slurp;
        my $about = decode_json($json);
        $list_name = $about->{name} if $about->{name};
    }

    # 5. Run

    my $email_count = 0;
    my $email_max   = scalar @email_filenames;
    foreach my $email_filename (@email_filenames) {
        $email_count++;

        my $email_json       = $email_filename->slurp;
        my $email_record     = decode_json($email_json);
        my $email_epoch_date = $email_record->{postDate};
        my $email_message_id = $email_record->{msgId};

        my $attachment_filename = $email_filename->filename;
        $attachment_filename =~ s/_raw\.json$/_attachments/;
        my $attachments_dir
            = io( $email_filename->filepath )->catdir($attachment_filename);

        if ( $email_record->{rawEmail} ) {
            my $raw_message = decode_entities( $email_record->{rawEmail} );

            $raw_message =~ s/\p{Zs}/ /gs;
            my $email = eval {
                local $SIG{__WARN__} = sub { };    # ignore warnings
                Email::MIME->new($raw_message);
            };

            # fixup attachments
            if ( $attachments_dir->exists and $attachments_dir->is_readable )
            {
                local $SIG{__WARN__} = sub { };
                $email->walk_parts(
                    sub {
                        my ($part) = @_;
                        local $SIG{__WARN__}
                            = undef;               # can emit lots of warnings
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
                                        = $attachment_file_on_disk->slurp;
                                    $part->body_set($attachment_contents);
                                }
                            }
                        }
                    }
                );
            }

            my $email_file = $destination_dir->file("$email_message_id.eml");
            $email_file->unlink;
            $email_file->utf8->print( $email->as_string );

            say "$list_name -> $email_count of $email_max" if $verbose;
        }
    }
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
