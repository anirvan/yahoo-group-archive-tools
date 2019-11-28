# yahoo-group-archive-tools

Converts a Yahoo group archive created by
[yahoo-group-archiver](https://github.com/IgnoredAmbience/yahoo-group-archiver)
into ordinary RFC822 email and mbox files that can be archived and
processed by other tools.

Requirements:

* Perl 5.14 or higher
* several Perl modules [installed via CPAN](https://foswiki.org/Support.HowToInstallCpanModules):
  - IO::All
  - HTML::Entities
  - JSON
  - Sort::Naturally
  - Text::Levenshtein::XS

Usage:
```
mkdir output-dir
yahoo-group-archive-tools.pl --source <archived-input-dir> --destination <output-dir>
```

## See also

* [IgnoredAmbiance's Yahoo Group Archiver](https://github.com/IgnoredAmbience/yahoo-group-archiver)
* [ArchiveTeam's Yahoo Groups overview](https://www.archiveteam.org/index.php?title=Yahoo!_Groups)

# Bugs and Todo

* mbox generation not built yet
* Closest file matches are currently checked against files on disk,
  rather than against those in the attachments info array. This means
  we might accidentally pick the wrong attachment in cases where the
  correct attachment hadn't been downloaded to disk.
* Some email parts are truncated at 64K. Need to investigate and flag.
* Need a minimum level of verbosity, just to know it's working. Maybe
  have a --quiet mode?
