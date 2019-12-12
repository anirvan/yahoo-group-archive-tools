# Yahoo Groups Archive Tools

Once you've backed up a Yahoo Group using [yahoo-group-archiver](https://github.com/IgnoredAmbience/yahoo-group-archiver), this script turns that into clean RFC822 email, mbox, and PDF files that can be archived and processed by other tools. This works on \*nix and Mac, but hasn't been tested on Windows.

## 1. Installation and usage

### Requirements

* Perl 5.14 or higher
* several Perl modules [installed via CPAN](https://foswiki.org/Support.HowToInstallCpanModules):
  - CAM::PDF
  - Email::MIME
  - Email::Sender
  - HTML::Entities
  - IO::All
  - JSON
  - Log::Dispatch
  - Sort::Naturally
  - Text::Levenshtein::XS
  - autodie

### Basic usage:

```
mkdir output-dir
yahoo-group-archive-tools.pl --source <archived-input-dir> --destination <output-dir>
```

### Experimental PDF support

Many non-technical users won't know what to do with an mbox file, but will appreciate getting a PDF file containing all the emails in the list. You can enable experimental PDF support by installing Andrew Ferrier's [email2pdf](https://github.com/andrewferrier/email2pdf) script. This is known to be buggy, and bug reports would be appreciated.

```
mkdir output-dir
yahoo-group-archive-tools.pl --source <archived-input-dir> --destination <output-dir> --pdf --email2pdf <path to email2pdf Python script>
```

### Output

The output directory will contain:

* An `email` folder containing standalone email files for every email in the archive, e.g. `email/1.eml`, `email/2.eml`. The emails won't be pristine, because Yahoo redacts email addresses (see that and other caveats below). The email IDs reflect those downloaded by yahoo-group-archiver, and it's normal to see some gaps in keeping with the original numering.
* A consolidated mailbox file, `mbox/list.mbox`, for the entire history of the list.
* With PDF support enabled, a `pdf-individual` directory containing individual PDFs for every email
* With PDF support enabled, a `pdf-combined` directory with a single PDF file containg every email

## 2. Learn more

* This tool builds on output from [IgnoredAmbiance's Yahoo Group Archiver](https://github.com/IgnoredAmbience/yahoo-group-archiver)
* Read more about the Yahoo Groups archiving process, the tools people are using, and the community of people doing the work at [ArchiveTeam Yahoo Groups project](https://www.archiveteam.org/index.php?title=Yahoo!_Groups)

## 3. Yahoo Groups API issues, and how we work around them

### 3.1. Censored email addresses (major problem)

The Yahoo Groups API redacts emails found in message headers. For
example, they'll rewrite `ceo@ford.com` as `ceo@...`.

Why is this bad?

* Deleting hostnames from headers could cause the emails to be unparseable by client software expecting valid hostnames.
* It's hard for people to tell the difference between users. For example, `ceo@ford.com` and `ceo@toyota.com` look the same if both are truncated to `ceo@...`.

#### How we're trying to fix it

Because the API tells us the submitting Yahoo user's username, we can make a fake email domain that preserves the part before the @ in redacted emails, while being unique per user.

* Imagine the CEO of Ford, `ceo@ford.com` (Yahoo ID `fordfan`), emails the list:
    * Yahoo Groups redacts the hostname, and saves that as `ceo@...`
    * We turn that it into `ceo@fordfan.yahoo.invalid`
* Then the CEO of Toyota, `ceo@toyota.com` (Yahoo ID `toyotalover123`), emails the list:
    * Yahoo Groups _also_ saves that as `ceo@...` even though this is a totally different person
    * But we turn that email it into `ceo@toyotalover123.yahoo.invalid`, which is different from `ceo@fordfan.yahoo.invalid`

We make this change in several headers that are guaranteed to include the original sender's email as part of it, including `From` and `Message-Id`. We save the original redacted version as an [X- header](https://tools.ietf.org/html/rfc822#section-4.7.4). For example, if Yahoo says an email is `From: ceo@...`, we modify that to `From: ceo@ceo123.yahoo.invalid`, and save the original as `X-Original-Yahoo-Groups-Redacted-From:` `ceo@...`.

### 3.2. Attachments

The Yahoo Groups API detaches all attachments, and saves them in a separate place.

#### Our solution

We try to stitch the emails back together, navigating through the [MIME structure](https://en.wikipedia.org/wiki/MIME) to attach the right attachment at the right place. In some cases, we're not able to identify where in the email MIME structure an attachment goes, so we reattach orphaned attachments to the whole email. In some cases, Yahoo doesn't give us the attachment, so we replace the attachment with a text part containing an error message, with original attachment-related headers added (`X-Yahoo-Groups-Attachment-Not-Found`, `X-Original-Content-Type`, `X-Original-Content-Disposition`, `X-Original-Content-Id`).

### 3.3. Long emails being truncated

The Yahoo Groups API forcibly truncates email messages with over 64 KB in text, and places a truncation message right in the middle of encoded content, e.g. Base64.

#### Our solution

Whenever we see an email body that end with `(Message over 64 KB, truncated)`, we remove that string from the broken message part, and pray that downstream parsers will be able to deal with truncated HTML, Base64, etc. We mark these message parts with a `X-Yahoo-Groups-Content-Truncated` header.

### 3.4. Character encoding issues

The Yahoo Groups API appears to be decoding and recoding textual message bodies, because [we see](https://yahoo.uservoice.com/forums/209451-us-groups/suggestions/9644478-displaying-raw-messages-is-not-8-bit-clean) Unicode ["U+FFFD" replacement characters](https://en.wikipedia.org/wiki/Specials_(Unicode_block)) in the raw RFC822 text that should be 7-bit clean. We're also seeing ^M linefeeds at the end of every header line and MIME body part.

#### Our solution

We remove invalid linefeeds and 8-bit characters from 7-bit RFC822 text.

## 4. Bugs and todo

* Capture email2pdf PDF conversion errors, instead of discarding them
* Catch and solve some of the most common email2pdf errors
* Maybe fix redacted headers in sub-parts so the message is valid
* Need to verify that attached files round trip correctly

## 5. Feedback

Feel free to use GitHub's issue tracker. If you need to contact me privately, DM me [@anirvan](https://twitter.com/anirvan) on Twitter.
