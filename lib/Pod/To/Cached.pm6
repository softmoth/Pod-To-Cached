unit class Pod::To::Cached;

use nqp;
use JSON::Fast;
use CompUnit::PrecompilationRepository::Document;

constant @extensions = <pod pod6 p6 pm pm6>;

constant INDEX = 'file-index.json';
enum Status is export <Current Valid Failed New Old>; # New is internally used, but not stored in DB

has Str $.path = '.pod6-cache';
has Str $.source = 'doc';
has Bool $.lazy;
has Bool $.verbose is rw;
has $.precomp;
has %.files;
has @!pods;
has Bool $.frozen = False;
has Str @.error-messages;
has Lock $!lock .= new;

submethod BUILD( :$!source = 'doc', :$!path = '.pod-cache',
    :$!lazy = False, :$!verbose = False )
{ }

submethod TWEAK {

    if $!path.IO ~~ :d {
        # cache path exists, so assume it should contain a cache
        die '$!path has corrupt doc-cache' unless ("$!path/"~INDEX).IO ~~ :f;
        my %config;
        try {
            my $config-content = ("$!path/"~INDEX).IO.slurp;
            %config = from-json($config-content);
            CATCH {
                default {
                    die "Configuration failed with: " ~ .message;
                }
            }
        }
        die "Invalid index file"
            unless
                %config<frozen>:exists
                and %config<files>:exists
                and %config<files>.WHAT ~~ Hash
        ;
        $!frozen = %config<frozen> eq 'True';
        unless $!frozen {
            die "Invalid index file"
                unless %config<source>:exists;
            $!source = %config<source>;
        }
        %!files = %config<files>;
        for %!files.keys -> $f {
            %!files{$f}<status> = Status(Status.enums{ %!files{$f}<status> // '' });
            die "File $f has no status" if not %!files{$f}<status>.defined;
            %!files{$f}<added> = DateTime.new( %!files{$f}<added> ).Instant
        }

        # note a frozen cache always returns True
        die "Source verification failed with:\n" ~ @!error-messages.join("\n\t")
            unless self.verify-source;
    }
    else {
        # check that a source exists before creating a cache
        $!frozen = False;
        die "Source verification failed with:\n" ~ @!error-messages.join("\n\t")
            unless self.verify-source;
        mkdir IO::Path.new( $!path );
        self.save-index;
    }

    my $precomp-store = CompUnit::PrecompilationStore::File.new(prefix => $!path.IO );
    $!precomp = CompUnit::PrecompilationRepository::Document.new(store => $precomp-store);

    # get handles for all Valid / Current files
    unless $!lazy {
        self!load-from-cache($_) for %!files.keys
    }

    note "Got cache at $!path" if $!verbose;
}

method !load-from-cache(Str $name) {
    note "Load '$name' from cache (%!files{$name}.raku())";
    with %!files{$name} {
        # XXX Is New OK here?
        return Nil unless .<status> ~~ Valid | Current | New;
        .<handle> = $!precomp.load(.<cache-key>)[0];
        my $updates;
        if (.<status> == New) {
            given self.compile( $name, .<cache-key>, .<path>, .<status> ) {
                if .<error>.defined {
                    @!error-messages.push: .<error>;
                    %!files{ .<source-name> }<status> = .<status> if .<status> ~~ Failed;
                }
                else {
                    %!files{ .<source-name> }<handle status added> = .<handle>, .<status>, .<added>;
                    $updates = True;
                }
            }
        }
        .<handle> or die "No handle for <$name> in cache, but marked as existing.",
                    " Cache corrupted.";
        self.save-index if $updates;
    }
}

method !add-file-to-cache(Str $pod-file) {
    my $nm = $!source eq "." ?? $pod-file !! $pod-file.substr($!source.chars + 1); # name from source root directory
    # Normalise the cache name to lower case
    $nm = $nm.subst(/ \. \w+ $/, '').lc;


    note "Adding '$nm' ($pod-file) to cache ({ %!files{$nm} // 'NULL' })";
    if %!files{$nm}:exists { # cannot use SetHash removal here because duplicates would then register as New
        if %!files{$nm}<path> eq $pod-file {
            note "Have the path: '%!files{$nm}<path>'";
            # detect tainted source
            %!files{$nm}<status> = Valid if %!files{$nm}<added> < %!files{$nm}<path>.IO.modified;
        }
        else {
            note "Maybe duplicates --- XXX handle this via exception.";
            @!error-messages.push("$pod-file duplicates name of " ~ %!files{$nm}<path> ~ " but with different extension");
        }
    }
    else {
        note "Adding new cache entry on the spot";
        %!files{$nm} = (:cache-key(nqp::sha1($nm)), :path($pod-file), :status( New ), :added(0) ).hash;
    }

    $nm
}

method !find-pod-file-of-name(Str $name) {
    die 'No files accessible for a frozen cache' if $!frozen; # should never get here

    # Reverse-engineer add-file-to-cache name transform
    my $path = $!source.IO;
    my @parts = $name.split('/');
    my $last = @parts.pop;
    for @parts -> $part {
        my $match = $path.dir(:test({ .lc eq $part }));
        if $match != 1 {
            # FIXME Need an exception here that can be caught
            die "No match for '$part' in '$path'";
        }
        $path = $match.first;
    }
    my $match = $path.dir(:test({ .IO.extension('').lc eq $last }));
    if $match != 1 {
        # FIXME Need an exception here that can be caught
        die "No match for '$last' in '$path'";
    }

    ~$match.first;
}

method verify-source( --> Bool ) {
    return True if $!frozen;

    (@!error-messages = "$!source is not a directory", ) and return False
        unless $!source.IO ~~ :d;
    return True if $!lazy;

    (@!error-messages = "No POD files found under $!source", ) and return False
        unless self.get-pods;

    @!error-messages = ();

    my SetHash $old .= new( %!files.keys );
    for @!pods -> $pfile {
        my $nm = self!add-file-to-cache($pfile);
        $old{$nm}--;
    }

    if $old.elems {
        note "Cache contains the following source names not associated with pod files:\n\t" ~ $old.keys.join("\n\t"),
            "\nConsider deleting and regenerating the cache to remove old files"
            if $!verbose;
        %!files{ $_ }<status> = Old for $old.keys;
    }
    =comment ary
        pod files that change their name, the cache will continue to contain old content
        TODO cache garbage collection: remove from cache

    note 'Source verified' if $!verbose;

    @!error-messages == 0
}

method update-cache( --> Bool ) {
    die 'Cannot update frozen cache' if $!frozen;
    @!error-messages = ();
    my Bool $updates;
    for %!files.kv -> $source-name, %info {
        next if %info<status> ~~ Current;
        given self.compile( $source-name, %info<cache-key>, %info<path>, %info<status> ) {
            if .<error>.defined {
                @!error-messages.push: .<error>;
                %!files{ .<source-name> }<status> = .<status> if .<status> ~~ Failed;
            }
            else {
                %!files{ .<source-name> }<handle status added> = .<handle>, .<status>, .<added>;
                $updates = True;
            }
        }
    }
    my $ret-ok = ?@!error-messages;
    note( @!error-messages.join("\n")) if $!verbose and not $ret-ok;
    self.save-index if $updates;
    note ('Cache ' ~ ( $ret-ok ?? '' !! 'not ' ) ~ 'fully updated') if $!verbose;
    $ret-ok
}

method compile( $source-name, $key, $path, $status is copy ) {
    note "Caching $source-name" if $!verbose;
    my ($handle, $error, $added);
    try {
        CATCH {
            default {
                $error = "Compile error in $source-name:\n\t" ~ .Str
            }
        }
        $!lock.protect( {
            $!precomp.precompile($path.IO, $key, :force );
            $handle = $!precomp.load($key)[0];
        })
    }
    with $handle {
        $status = Current;
        $added = now ;
    }
    else {
        $status = Failed if $status ~~ New ; # those marked Valid remain Valid
        note "$source-name failed to compile" if $!verbose;
        $error = 'unknown precomp error' without $error; # make sure that $error is defined for no handle
    }
    %(:$error, :$handle, :$added, :$status, :$source-name)
}

method save-index {
    my %h = :frozen( $!frozen ), :files( (
        gather for %!files.kv -> $fn, %inf {
            next if %inf<status> ~~ New; # do not allow New to be saved in index
            if $!frozen {
                take $fn => (
                    :cache-key(%inf<cache-key>),
                    :status( "Current" ),
                    :added( %inf<added> ),
                ).hash
            }
            else {
                take $fn => (
                    :cache-key(%inf<cache-key>),
                    :status( %inf<status> ),
                    :added( %inf<added> ),
                    :path(%inf<path>),
                ).hash
            }
        } ).hash );
    %h<source> = $!source unless $!frozen;
    ("$!path/"~INDEX).IO.spurt: to-json(%h);
}

method get-pods {
    die 'No pods accessible for a frozen cache' if $!frozen; # should never get here
    return @!pods if @!pods;
    #| Recursively finds all pod files
     @!pods = my sub recurse ($dir) {
         gather for dir($dir) {
             take .Str if  .extension ~~ any( @extensions );
             take slip sort recurse $_ if .d;
         }
     }($!source); # is the first definition of $dir
}

method pod( Str $source-name ) is export {
    unless %!files{$source-name}:exists {
        if $!lazy {
            my $pod-file = self!find-pod-file-of-name($source-name);
            note "Found '$pod-file' for '$source-name'";
            self!add-file-to-cache($pod-file);
        }
        else {
            die "Source name ｢$source-name｣ not in cache";
        }
    }
    self!load-from-cache($source-name) unless %!files{$source-name}<handle>:exists;
    %!files{$source-name}<handle> or
        die "Attempt to obtain non-existent POD for <$source-name>.",
            " Is the source new and failed to compile?",
            " Has the cache been updated?";
    nqp::atkey(%!files{$source-name}<handle>.unit,'$=pod');
}

proto method list-files(| ) {*}

multi method list-files( Str $s --> Positional ) {
    return () unless $s ~~ any(Status.enums.keys);
    gather for %!files.kv -> $pname, %info {
        take $pname if %info<status> ~~ $s
    }.sort.list
}

# The following is ugly, but cleaner ways seem to choke when list-file str returns Nil

multi method list-files( *@statuses --> Positional ) {
    my @s;
    for @statuses {
        my @a = self.list-files( $_ );
        @s.append(  |@a ) if @a
    }
    @s.sort.list
}

multi method hash-files( --> Hash) {
    ( gather for %.files.kv -> $pname, %info {
        take $pname => %info<status>.Str
    }).hash
}

multi method hash-files( @statuses --> Hash ) {
    ( gather for %.files.kv -> $pname, %info {
        take $pname => %info<status>.Str if %info<status> ~~ any( @statuses )
    }).hash
}

method cache-timestamp( $source --> Instant ) {
    %!files{ $source }<added>
}

method freeze( --> Bool ) {
    return if $!frozen;
    my @not-ok = gather for %!files.kv -> $pname, %info {
        take "$pname ({%info<status>})" unless %info<status> ~~ Current
    }
    die "Cannot freeze because some files not Current:\n" ~ @not-ok.join("\n\t")
        if @not-ok;
    $!frozen = True;
    self.save-index;
}

sub rm-cache( $path ) is export {
    if $*SPEC ~~ IO::Spec::Win32 {
        my $win-path = "$*CWD/$path".trans( ["/"] => ["\\"] );
        shell "rmdir /S /Q $win-path" ;
    } else {
        shell "rm -rf $path";
    }
}

=begin pod

=TITLE Pod::To::Cached

=SUBTITLE Create a precompiled cache of POD files

Module to take a collection of POD files and create a precompiled cache. Methods / functions
to add a POD file to a cache.

=begin SYNOPSIS
use Pod::To::Cached;

my Pod::To::Cached $cache .= new(:path<path-to-cache>, :source<path-to-directory-with-pod-files>);

$cache.update-cache;

for $cache.hash-files.kv -> $source-name, $status {
    given $status {
        when 'Current' {say "｢$source-name｣ is up to date with POD source"}
        when 'Valid' {say "｢$source-name｣ has valid POD, but newer POD source contains invalid POD"}
        when 'Failed' {say "｢$source-name｣ is not in cache, and source file contains invalid POD"}
        when 'New' { say "｢$source-name｣ is not in cache and cache has not been updated"}
        when 'Old' { say "｢$source-name｣ is in cache, but has no associated pod file in DOC"}
    }
    user-supplied-routine-for-processing-pod( $cache.pod( $source-name ) );
}

# Find files with status
say 'These pod files failed:';
.say for $cache.list-files( 'Failed' );
say 'These sources have valid pod:';
.say for $cache.list-files(<Current Valid>);

# Find date when pod added to cache
my $source = 'language/pod'; # name of a documentation source
say "｢$source｣ was added on ｢{ $cache.cache-timestamp( $source ) }｣";

# Remove the dependence on the pod source
$cache.freeze;

=end SYNOPSIS

=item Str $.path = '.pod6-cache'
    path to the directory where the cache will be created/kept

=item Str $!source = 'doc'
    path to the collection of pod files
    ignored if cache frozen

=item constant @extensions = <pod pod6 p6 pm pm6>
    the possible extensions for a POD file

=item verbose = False
    Whether processing information is sent to stderr.

=begin item
    new
    Instantiates class. On instantiation,
=item2 get the cache from index, or creates a new cache if one does not exist
=item2 if frozen, does not check the source directory
=item2 if not frozen, or new cache being created, verifies
=item3  source directory exists
=item3 no duplicate pod file names exist, eg. xx.pod & xx.pod6
=item2 verifies whether the cache is valid
=end item

=item update-cache
    All files with a modified timestamp (reported by the filesystem) after the added instant are precompiled and added to the cache
=item2 Status is changed to Updated (compiles Valid) or Fail (does not compile)
=item2 Failed files that were previously Valid files still retain the old cache handle
=item2 Throws an exception when called on a frozen cache

=item freeze
    Can be called only when there are only Valid or Updated (no New, Tainted or Failed files),
    otherwise dies.
    The intent of this method is to allow the pod-cache to be copied without the original pod-files.
    update-cache will throw an error if used on a frozen cache

=item list-files( Str $s --> Positional )
    returns a Sequence of files with the given status

=item list-files( Str $s1, $s2 --> Positional )
    returns a Sequence of files with the given status list

=item hash-files( *@statuses? --> Associative )
    returns a map of the source-name and its statuses
=item2 explicitly give required status strings: C<< $cache.hash-files(<Old Failed>) >>
=item2 return all files C< $cache.hash-files >

=item cache-timestamp( $source --> Instant )
    returns the Instant when a valid version of the Pod was added to the cache
=item2 if the time-stamp is before the time the Pod was modified, then the pod has errors
=item2 a Failed source has a timestamp of zero

=item pod
    method pod(Str $source)
    Returns an array of POD Objects generated from the file associated with $source name.
    When a doc-set is being actively updated, then pod files may have failed, in which case they have C<Status> = C<Valid>.
    To froze a cache, all files must have Current status

=item Status is an enum with the following elements and semantics
=defn Current
    There is a compiled source in the cache with an added date *after* the modified date
=defn Valid
    There is a compiled source in the cache with an added date *before* the modified date and there has been an attempt to add the source to cache that did not compile
=defn Failed
    There is not a compiled source in the cache, but there has been an attempt to add the source name to the cache that did not compile
=defn New
    A new pod source has been detected that is not in cache, but C<update-cache> has not yet been called to compile the source. A transitional Status
=defn Old
    A source name that is in the cache but no longer reflects an existing source.

=item rm-cache

Deletes the whole directory tree that holds the cache in an OS-independent way.

=end pod
