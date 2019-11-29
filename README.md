# Yahoo Groups Archive Tools

Once you've backed up a Yahoo Group using
[yahoo-group-archiver](https://github.com/IgnoredAmbience/yahoo-group-archiver),
this script turns that into ordinary RFC822 email and mbox files that
can be archived and processed by other tools.

## Installation and usage

Requirements:

* Perl 5.14 or higher
* several Perl modules [installed via CPAN](https://foswiki.org/Support.HowToInstallCpanModules):
  - Email::Sender
  - HTML::Entities
  - IO::All
  - JSON
  - Sort::Naturally
  - Text::Levenshtein::XS
  - autodie

Usage:

```
mkdir output-dir
yahoo-group-archive-tools.pl --source <archived-input-dir> --destination <output-dir>
```

The output directory will contain:

* Standalone email files for every email in the archive, e.g. `1.eml`,
  `2.eml`. The emails won't be pristine, because Yahoo redacts email
  addresses (see that and other caveats below). The email IDs reflect
  those downloaded by yahoo-group-archiver, and it's normal to see
  some gaps in keeping with the original numering.
* A consolidated mailbox file, `list.mbox`, for the entire history of
  the list.

## Learn more

* [IgnoredAmbiance's Yahoo Group Archiver](https://github.com/IgnoredAmbience/yahoo-group-archiver)
* [ArchiveTeam's Yahoo Groups overview](https://www.archiveteam.org/index.php?title=Yahoo!_Groups)

## Yahoo Groups API issues, and how we work around them

### 1. Censored email addresses (major problem)

The Yahoo Groups API redacts emails found in message headers and
bodies, so "ceo@ford.com" becomes "ceo@...". When they redact email
addresses found in headers, they mess with MessageIDs, From lines,
etc.

* In some cases, deleting hostnames from headers causes the emails to
  be unparseable by client software that expect valid hostnames.

* And it also causes problems for humans trying to tell the difference
  between users with similar emails. For example, you can't tell the
  difference between ceo@gm.com and ceo@toyota.com when both users'
  emails are truncated down to "ceo@..."

This tool attempts to compensate for this. Because the API tells us
the submitting Yahoo user's username, we can make a fake email domain
that preserves the part before the @ in redacted emails, while being
unique per user.

* User ceo@ford.com> (Yahoo ID 'ceo123') emails the list
    * Yahoo Groups saves that as "ceo@..."
    * We turn that it into ceo@ceo123.yahoo.invalid
* User ceo@toyota.com (Yahoo ID 'carluvr') emails list
    * Yahoo Groups saves that as "ceo@..."
    * We turn that it into ceo@carluvr.yahoo.invalid

We make this change in several headers that are guaranteed to include
the original sender's email as part of it, including 'From' and
'Message-Id'. We save the original redacted version as an addition X-
header.

* Yahoo says an email is "From: ceo@..."
* We change that to "From: ceo@ceo123.yahoo.invalid"
* We add a "X-Original-Yahoo-Groups-Redacted-From: ceo@..." header

### 2. Attachments

The Yahoo Groups API detaches all attachments, and saves them
separately. We do our best to stitch the emails back together,
carefully walking through the MIME structure to attach the right
attachment at the right place. In some cases, we're not able to
identify which part an attachment goes, so we end up reattaching it to
the whole email. In rare cases, we couldn't get the attachment from
Yahoo, or they never saved the attachment, so you'll see email bodies
that say '[ Attachment content not displayed ]'.

### 3. Character encoding issues

Maybe because they have to redact email bodies, Yahoo appears to be
decoding and recoding textual message bodies, and adding ^M linefeeds
at the end of every header line and MIME body part. When they have
encoding/recoding issues, we'll sometimes see a random Unicode
["U+FFFD" replacement
character](https://en.wikipedia.org/wiki/Specials_(Unicode_block)) in
the raw RFC822 text. We go ahead and delete both those linefeeds (to
preserve the original format) and the U+FFFD characters (to keep the
raw emails 7-bit clean).

## Bugs and todo

* Closest file matches are currently checked against files on disk,
  rather than against those in the attachments info array. This means
  we might accidentally pick the wrong attachment in cases where the
  correct attachment hadn't been downloaded to disk.
* Some email parts are truncated at 64K. Need to investigate and flag.
* Need a minimum level of verbosity, just to know it's working. Maybe
  have a --quiet mode?
* Maybe fix redacted headers in sub-parts so the message is valid
* Need to verify that attached files round trip correctly

## Feedback

Feel free to use GitHub's issue tracker. If you need to contact me
privately, DM me @anirvan on Twitter.
