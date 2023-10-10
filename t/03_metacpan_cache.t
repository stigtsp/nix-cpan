use v5.38;
use Test::More;
use Data::Dumper;


use_ok("Nix::MetaCPANCache");
use_ok("Nix::Util", qw(distro_name_to_attr));
my $db_test_file = '/var/tmp/metacpan-cache-test.db';

my $mcc = new_ok( "Nix::MetaCPANCache" => [ cache_file => 't/var/metacpan-download-cache.jsonl.gz',
                                            db_file    => '/var/tmp/metacpan-cache-test.db' ],
                  "Nix::MetaCPANCache" );


# We only run update if the db file doesnt exist, since it is a bit slowish
unless (-f $db_test_file) {
  $mcc->update();
}

my $moose = $mcc->get_by(distribution => "Moose");
is($moose->name, "Moose-2.2206");
is($moose->distribution, "Moose");
is($moose->main_module, "Moose");

is_deeply( [ $moose->propagated_build_inputs ],
           [
             'ClassLoad',
             'ClassLoadXS',
             'DataOptList',
             'DevelGlobalDestruction',
             'DevelOverloadInfo',
             'DevelStackTrace',
             'DistCheckConflicts',
             'EvalClosure',
             'MROCompat',
             'ModuleRuntime',
             'ModuleRuntimeConflicts',
             'PackageDeprecationManager',
             'PackageStash',
             'PackageStashXS',
             'ParamsUtil',
             'SubExporter',
             'TryTiny'
         ],
         "calculated propagated_build_inputs for Moose match"
       );

is_deeply( [ map { $_->attrname }
             $moose->dependency(["runtime"], ["recommends"])->@* ],
           [ 'DataOptList' ] );

is_deeply( [ map { $_->attrname }
             $moose->dependency(["runtime"], ["suggests"])->@* ],
           [ 'DevelPartialDump' ] );





my $cryptx = $mcc->get_by(distribution => "CryptX");
is($cryptx->name, "CryptX-0.078");
is($cryptx->distribution, "CryptX");
is($cryptx->main_module, "CryptX");

is_deeply($cryptx->data->{dependency}, [
          {
            'version' => '0',
            'module' => 'ExtUtils::MakeMaker',
            'relationship' => 'requires',
            'phase' => 'configure'
          },
          {
            'version' => '0',
            'phase' => 'test',
            'relationship' => 'requires',
            'module' => 'Test::More'
          },
          {
            'version' => '0',
            'phase' => 'runtime',
            'module' => 'Math::BigInt',
            'relationship' => 'requires'
          },
          {
            'phase' => 'runtime',
            'module' => 'perl',
            'relationship' => 'requires',
            'version' => '5.006'
          },
          {
            'relationship' => 'requires',
            'module' => 'ExtUtils::MakeMaker',
            'phase' => 'build',
            'version' => '0'
          }
        ]);


is_deeply( [ map { $_->attrname } $cryptx->dependency([qw(runtime)])->@* ],
           [  ]);

is_deeply( [ map { $_->attrname } $cryptx->dependency([qw(build test configure)])->@* ],
           [  ]);


done_testing();
