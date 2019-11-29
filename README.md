# Yahoo Groups Archive Tools

Once you've backed up a Yahoo Group using
[yahoo-group-archiver](https://github.com/IgnoredAmbience/yahoo-group-archiver),
this script turns that into ordinary RFC822 email and mbox files that
can be archived and processed by other tools.

## 1. Installation and usage

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

## 2. Learn more

* This tool builds on output from [IgnoredAmbiance's Yahoo Group
  Archiver](https://github.com/IgnoredAmbience/yahoo-group-archiver)
* Read more about the Yahoo Groups archiving process, the tools people
  are using, and the community of people doing the work at
  [ArchiveTeam Yahoo Groups
  project](https://www.archiveteam.org/index.php?title=Yahoo!_Groups)

## 3. Yahoo Groups API issues, and how we work around them

### 3.1. Censored email addresses (major problem)

The Yahoo Groups API redacts emails found in message headers. For
example, they'll rewrite `ceo@ford.com` as `ceo@...`.

Why is this bad?

* Deleting hostnames from headers could cause the emails to be
  unparseable by client software expecting valid hostnames.

* It can also cause problems for humans trying to tell the difference
  between users. For example, you can't tell the difference between
  `ceo@ford.com` and `ceo@toyota.com` when both are truncated to
  `ceo@...`.

#### How we're trying to fix it

Because the API tells us the submitting Yahoo user's username, we can
make a fake email domain that preserves the part before the @ in
redacted emails, while being unique per user.

* User `ceo@ford.com` (Yahoo ID `ceo123`) emails the list
    * Yahoo Groups saves that as `ceo@...`
    * We turn that it into `ceo@ceo123.yahoo.invalid`
* User `ceo@toyota.com` (Yahoo ID `carluvr`) emails list
    * Yahoo Groups saves that as `ceo@...`
    * We turn that it into `ceo@carluvr.yahoo.invalid`

We make this change in several headers that are guaranteed to include
the original sender's email as part of it, including `From` and
`Message-Id`. We save the original redacted version as an addition X-
header.

* Yahoo says an email is `From: ceo@...`
* We change that to `From: ceo@ceo123.yahoo.invalid`
* We save the original version in a `X-Original-Yahoo-Groups-Redacted-From:` `ceo@...` header

### 3.2. Attachments

The Yahoo Groups API detaches all attachments, and saves them
separately.

#### Our solution

We try stitch the emails back together, navigating through the MIME
structure to attach the right attachment at the right place. In some
cases, we're not able to identify which part an attachment goes, so we
end up reattaching it to the whole email. In rare cases, we couldn't
get the attachment from Yahoo, or they never saved the attachment, so
you'll see email bodies that say
`[ Attachment content not displayed ]`.

### 3.3. Character encoding issues

Maybe because they have to redact email bodies, Yahoo appears to be
decoding and recoding textual message bodies, and adding ^M linefeeds
at the end of every header line and MIME body part. When they have
encoding/recoding issues, we'll sometimes see a random Unicode
["U+FFFD" replacement
character](https://en.wikipedia.org/wiki/Specials_(Unicode_block)) in
the raw RFC822 text.

#### Our solution

We and delete both the linefeeds (to preserve the original format) and
the U+FFFD characters (to keep the raw emails 7-bit clean).

## 4. Bugs and todo

* When we munge MessageIDs, we also kill threading. Need to fix!
* Closest file matches are currently checked against files on disk,
  rather than against those in the attachments info array. This means
  we might accidentally pick the wrong attachment in cases where the
  correct attachment hadn't been downloaded to disk.
* Some email parts are truncated at 64K. Need to investigate and flag.
* Need a minimum level of verbosity, just to know it's working. Maybe
  have a --quiet mode?
* Maybe fix redacted headers in sub-parts so the message is valid
* Need to verify that attached files round trip correctly

## 5. Feedback

Feel free to use GitHub's issue tracker. If you need to contact me
privately, DM me @anirvan on Twitter.
