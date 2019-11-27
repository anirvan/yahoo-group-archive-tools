# yahoo-group-archive-tools

Converts a Yahoo group archive created by
[yahoo-group-archiver](https://github.com/IgnoredAmbience/yahoo-group-archiver)
into ordinary email and mbox files that can be archived and processed
by other tools.

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
