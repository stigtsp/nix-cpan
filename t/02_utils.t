use v5.38;
use Test::More;

use_ok("Nix::Util", qw(sha256_hex_to_sri distro_name_to_attr license_map render_license));

is(sha256_hex_to_sri("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),"sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=");
is(distro_name_to_attr("DBD-SQLite"), "DBDSQLite");
is_deeply(license_map("perl_5"),
          { licenses => [ qw( artistic1 gpl1Plus ) ] });

is(render_license("perl_5"), "with lib.licenses; [ artistic1 gpl1Plus ]");

done_testing();
