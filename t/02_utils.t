use v5.38;
use Test::More;
use MIME::Base64 qw(encode_base64 decode_base64);

use_ok("Nix::Util", qw(sha256_hex_to_sri distro_name_to_attr license_map render_license));

is(sha256_hex_to_sri("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),"sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=");

# Regression: a digest with leading zero byte(s) must still encode 32 bytes.
# (Math::BigInt->to_bytes stripped them, producing a short/wrong hash for ~1/256
# of releases.)
{
  my $zero = "00" . ("ab" x 31);   # 64 hex chars, leading 0x00
  my $sri = sha256_hex_to_sri($zero);
  (my $b64 = $sri) =~ s/^sha256-//;
  is(length(decode_base64($b64)), 32, "leading-zero sha256 encodes a full 32 bytes");
  is($sri, "sha256-" . encode_base64(pack("H*", $zero), ""), "matches pack('H*') encoding");
}

# Format guard: reject non-64-hex input rather than silently mis-encode.
eval { sha256_hex_to_sri("deadbeef") };
like($@, qr/expected 64 hex chars/, "sha256_hex_to_sri rejects wrong-length hex");
eval { sha256_hex_to_sri("z" x 64) };
like($@, qr/expected 64 hex chars/, "sha256_hex_to_sri rejects non-hex");
is(distro_name_to_attr("DBD-SQLite"), "DBDSQLite");
is_deeply(license_map("perl_5"),
          { licenses => [ qw( artistic1 gpl1Plus ) ] });

is(render_license("perl_5"), "with lib.licenses; [ artistic1 gpl1Plus ]");

eval { sha256_hex_to_sri("") };
like($@, qr/requires a non-empty hex string/, "sha256_hex_to_sri dies on empty string");
eval { sha256_hex_to_sri(undef) };
like($@, qr/requires a non-empty hex string/, "sha256_hex_to_sri dies on undef");

done_testing();
