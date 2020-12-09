# nix-update-perl-packages

## TODO
- [ ] versions (use Sort::Versions)
  - [ ] only update if cpan is newer, if local is newer skip (example Crypt::SSLeay)
  - [ ] update url, version, sha256 if newer exists
  - [ ] dont update pre$ versions
- [ ] git support
  - [ ] --commit 
  - [ ] --dry-run for testing
  - check that branch is not master
- corner cases
  - [ ] try to work out errata
  - [ ] some cases have distribution as pname, not module
  - ...
- end report (upgraded, skipped, etc) for pasting into PR
