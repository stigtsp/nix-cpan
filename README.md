# nix-update-cpan

## TODO
- [X] versions (use Sort::Versions)
  - [X] only update if cpan is newer, if local is newer skip (example Crypt::SSLeay)
  - [X] update url, version, sha256 if newer exists
  - [X] dont update pre$ versions
- [X] git support
  - [X] --commit 
  - [X] ~option to~ don't sign commits
  - [X] ~--dry-run~ omit --commit for testing
  - [X] check that branch is not master
- [x] add `verify_SSL => 1` to HTTP::Tiny usage
- corner cases
  - [ ] try to work out errata
  - [X] some cases have distribution as pname, not module
  - ...
- support cleanups
  - [ ] figure out and update `propagatedBuildInputs`, `buildInputs`, etc
- end report (upgraded, skipped, etc) for pasting into PR
- tests
  - [ ] perlcritic
  - [ ] unit tests for some pure functions
  - [ ] mocked metacpan_api tests with `Test::Mock::HTTP::Tiny`
  - ...
