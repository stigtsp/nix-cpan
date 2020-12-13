# nix-update-perl-packages

## TODO
- [ ] versions (use Sort::Versions)
  - [X] only update if cpan is newer, if local is newer skip (example Crypt::SSLeay)
  - [X] update url, version, sha256 if newer exists
  - [ ] dont update pre$ versions
- [ ] git support
  - [ ] --commit 
  - [ ] option to not sign commits
  - [ ] --dry-run for testing
  - check that branch is not master
- corner cases
  - [ ] try to work out errata
  - [X] some cases have distribution as pname, not module
  - ...
- end report (upgraded, skipped, etc) for pasting into PR
