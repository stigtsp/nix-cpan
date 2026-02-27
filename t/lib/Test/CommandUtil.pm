package Test::CommandUtil;

use v5.38;
use strict;
use warnings;
use Exporter 'import';
use IPC::Cmd qw(run);

our @EXPORT_OK = qw(run_cmd run_ok git_cmd git_ok run_nix_cpan);

sub run_cmd (@cmd) {
  my ($ok, $err, $buf) = run(command => \@cmd);
  my $out = join("", ($buf // [])->@*);
  return {
    ok  => $ok ? 1 : 0,
    err => $err,
    buf => $buf // [],
    out => $out,
  };
}

sub run_ok ($name, @cmd) {
  my $res = run_cmd(@cmd);
  Test::More::ok($res->{ok}, $name);
  return $res;
}

sub git_cmd ($repo, @args) {
  return run_cmd(
    "env",
    "GIT_CONFIG_NOSYSTEM=1",
    "GIT_CONFIG_GLOBAL=/dev/null",
    "HOME=$repo",
    "XDG_CONFIG_HOME=$repo/.xdg-config",
    "git",
    "-C",
    $repo,
    @args
  );
}

sub git_ok ($name, $repo, @args) {
  return run_ok($name, "git", "-C", $repo, @args);
}

sub run_nix_cpan ($cache_home, $extra_env, @args) {
  my @cmd = ("env", "XDG_CACHE_HOME=$cache_home");
  if ($extra_env && ref($extra_env) eq "HASH") {
    push @cmd, map { $_ . "=" . $extra_env->{$_} } sort keys %$extra_env;
  }
  push @cmd, "perl", "nix-cpan.pl", @args;
  return run_cmd(@cmd);
}

1;
