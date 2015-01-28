#!/usr/bin/env perl

# script to analyze glopad tables to guess
# forigne keys based on column names.

# bdc34 2015-01-24

use strict;

use Data::Dump qw(dump);
use Class::Inspector;

use DBI;

my $debug = 0;

my $dbname = 'glopad';
my $username = $ARGV[0];
my $pw = $ARGV[1];
my $host = 'localhost';
my $port = 5432;

#added to d2rq skip tables
my @skip_tables=(
                 'c_aaa_test',
                 '/field_.*/',
                 '/.*_ml/',
                 '/i_.*/',
                 '/p_.*/',
                 '/pg_.*/',);

#These are d_ tables that have their primary keys forced to a specific column
my %force_pkey=(
                'd_pa_altnametype', 'altnametypeid',
                'd_performing_arts', 'paid',
                'd_pa_alt_name', 'altnameid',
                'd_production_artsofperformance', 'artsofperformanceid',
                'd_bibliography', 'biblioid'
);

### connect to db ###

my $dbh =DBI->connect("dbi:Pg:dbname=$dbname;host=$host;port=$port;", "$username", "$pw");
use DBD::Pg qw(:pg_types);


### Utility routines ###

sub make_pk_names{
  my $table = shift;
  my @rv = ();

  if( $force_pkey{$table} ){
    push @rv, $force_pkey{$table};
  }

  my $expectedPk = $table;
  $expectedPk =~ /d_(.*)/;
  $expectedPk = $1;
  push @rv, $expectedPk.'id';

  $expectedPk =~ s/_//g;
  push @rv, $expectedPk.'id';


  if( $table =~ /^d_biblio.*/ ) {
    (my $bt = $table ) =~ s/d_biblio_// ;
    push @rv, $bt.'id';

    (my $bt2 = $bt) =~ s/_//g;
    push @rv, $bt2.'id'
  }
  return \@rv;
}

sub table_count{
 my $table = shift;
 my $sth = $dbh->prepare('select count(*) from '.$table);
 $sth->execute(  );
 my @data = $sth->fetchrow_array();
 return $data[0];
}

sub is_table_empty{
  my $table = shift;
  return (table_count($table) == 0) ;
}

sub column_count{
 my ($table, $col) = @_;
 my $sth = $dbh->prepare('select count(*) from '.$table. ' where '.$col.' is not null' );
 $sth->execute(  );
 my @data = $sth->fetchrow_array();
 return $data[0];
}

sub is_column_empty{
  my ($table, $col) = @_;
  return column_count($table,$col) == 0;
}

sub is_column_always_populated{
 my ($table, $col) = @_;
 my $tablecount = table_count($table);
 return 1 if( $tablecount == 0 );

 my $colcount = column_count($table,$col);
 return $colcount == $tablecount;
}


### connect to db ###

my $dbh =DBI->connect("dbi:Pg:dbname=$dbname;host=$host;port=$port;", "$username", "$pw");
use DBD::Pg qw(:pg_types);

### get all tables and columns ###

my $sth = $dbh->prepare("select table_name, column_name, data_type  " .
                        "from INFORMATION_SCHEMA.COLUMNS where table_schema = 'public'");
$sth->execute( );
my $tbl_ary_ref = $sth->fetchall_arrayref;

# filter out non d_ tables and multi language tables
my @d_tables =
  grep { @{$_}[0] !~ /.*_ml/ }
  grep { @{$_}[0] =~ /^d_.*/ }
  @{$tbl_ary_ref};

my @r_tables =
  grep { @{$_}[0] !~ /.*_ml/ }
  grep { @{$_}[0] =~ /^r_.*/ }
  @{$tbl_ary_ref};

my $d_pkeys = {};
my $d_pkey_names = {};

### try to guess the pkey for each d_ table ###
foreach my $row (@d_tables) {
  print "  ".(join(',',@{$row}))."\n" if ($debug);;

  my $table = @{$row}[0];
  my $column = @{$row}[1];

  if( ! defined $d_pkeys->{$table} ){
    $d_pkeys->{$table}->{columns} = $column;
    $d_pkeys->{$table}->{pk} = 'unknown';
  }else{
    $d_pkeys->{$table}->{columns} = $d_pkeys->{$table}->{columns} . ",$column";
  }

  print "possible pks: " . join(',',@{make_pk_names($table)}) . "\n"  if ($debug);;
  if( $column ~~ @{make_pk_names( $table )} ) {
    $d_pkeys->{$table}->{pk} = $column;
    $d_pkey_names->{$column} = $table;
  }
}

print "\n\n ************** These are the primary keys of the D tables:\n";
print dump( $d_pkeys ) . "\n" ;

my %columnToDtable = ();

print "\n\n ************* These D table don't have pkeys: \n";


foreach my $dtableName ( keys %{$d_pkeys} ){
  if( $d_pkeys->{$dtableName}->{pk} eq 'unknown' ){
    print "table $dtableName with columns  " . $d_pkeys->{$dtableName}->{columns} . "\n";
  }else{
    if( defined $d_pkeys->{$dtableName}->{pk} ) {
      my $pk = $d_pkeys->{$dtableName}->{pk};
      $columnToDtable{$pk} = $dtableName;
    }
  }
}

print "column name to d_ table: ". dump ( \%columnToDtable ) if ($debug);

### TODO: Now loop through r table and their columns, look for tables
### with columns unaccounted for in d_ tables.

my $r_pkeys = {};

foreach my $row (@r_tables){
  my $table = @{$row}[0];
  my $column = @{$row}[1];

  if( ! defined $r_pkeys->{$table} ){
    $r_pkeys->{$table}->{columns} = $column;
  }else{
    $r_pkeys->{$table}->{columns} = $r_pkeys->{$table}->{columns} . ",$column";
  }
}

my @empty_tables=();
my @r_basic =();
my @r_missing_pk =();
my @r_three =();
my @r_complex=();

foreach my $rtableName ( keys  %{$r_pkeys} ){
  my $allFound=1;
  my @columns = split ',', $r_pkeys->{$rtableName}->{columns} ;

  my @outcolumns = ();

  foreach my $column ( @columns ){
    my $msg ='';
    if( is_column_empty($rtableName, $column)){
      $msg .= "(always null)" ;
    }elsif( !is_column_always_populated( $rtableName, $column)){
      $msg = "(not always populated)" ;
    }

    if( $d_pkey_names->{$column} ){
      #found f key
      $r_pkeys->{$rtableName}->{fk}->{$column} = $d_pkey_names->{$column};
      push @outcolumns, $column . $msg;
    }else{
      # no f key found
      # maybe it's empty
      if( is_column_empty( $rtableName, $column)){
        push @outcolumns, $column."(but all null)";
      }else{
        $r_pkeys->{$rtableName}->{missing_fk}->{$column}=1;
        $allFound = 0;
        push @outcolumns, $column."(no d_ key found)".$msg;
      }
    }
  }

  my $table =  "$rtableName,".(join ',' , @outcolumns);
  if( is_table_empty( $rtableName )){
    push @empty_tables, $table;
  }elsif( scalar @columns == 2 && $allFound ){
    push @r_basic,$table;
  }elsif ( scalar @columns == 3 && $allFound ){
    push @r_three, $table;
  }elsif ( scalar @columns > 3 && $allFound ){
    push @r_complex, $table;
  }else{
    push @r_missing_pk, $table;
  }

}

print "\n\n";
print "empty tables: \n" . (join "\n", @empty_tables) . "\n\n";
print "r_ tables with unknown forign keys:\n" . (join "\n", @r_missing_pk) . "\n\n";
print "Complex r_ table with more than 3 forign keys:\n" . (join "\n", @r_complex) . "\n\n";
print "Three column r_ :\n" . (join "\n", @r_three) . "\n\n";
print "Two column r_ :\n" . (join "\n", @r_basic) . "\n\n";

#
#
# Write skip table file
#
#

my $sth = $dbh->prepare('select table_name from INFORMATION_SCHEMA.views');
$sth->execute();
my @views = ();
my @row = ();
while(@row = $sth->fetchrow_array){
  push @views, @row[0];
}
my $skip = 'skiptables.txt';
open(my $fh, '>', $skip) or die "Could not open file '$skip' $!";
my @empty_table_names = map { (split ',',$_)[0] } @empty_tables;
print $fh (join "\n", (@empty_table_names, @skip_tables, @views) );
close $fh;

#
#
# Generate the d2rq mapping.
#
#
my $output_map = "glopad-mapping.ttl";
my $user = "bdc34";
my $pw = "xyz";


my $d2rq_cmd = "./generate-mapping -o $output_map"
  ." -u $user -p $pw "
  ." --skip-tables @" . $skip
  ." -d org.postgresql.Driver jdbc:postgresql:glopad";

print "$d2rq_cmd\n";

`$d2rq_cmd`;

open (my $fh, '>>', $output_map) or die "Could not open $output_map to add mappings $!";

#
# Here we are making the d2rq:PropertyBridge constilations for
# the basic 2 column r_ tables.
#
# These get appended to the mapping file.
#

foreach my $rtableLine ( @r_basic ){

  my($rtable,$colA,$colB) = split ',',$rtableLine;

  if( is_table_empty( $rtable ) ){
    print $fh "# Table $rtableLine is empty so it is not getting mapped\n\n";
    next;
  }

  my $colA_dtable = $columnToDtable{$colA};
  my $colB_dtable = $columnToDtable{$colB};

  #  uri of PropertyBridge
  my $propBridgeUri = "map:${colA_dtable}_to_${colB_dtable}";
  #  uri of new property
  my $propUri = "vocab:${colA_dtable}_to_${colB_dtable}";

  #uri of ClassMap this bridge belongs to
  my $classMapAUri = "map:$colA_dtable";
  my $classMapBUri = "map:$colB_dtable";

  print $fh "$propBridgeUri a d2rq:PropertyBridge;\n".
    "d2rq:belongsToClassMap $classMapAUri;\n".
    "d2rq:property $propUri;\n".
    "d2rq:refersToClassMap $classMapBUri;\n".
    "d2rq:join \"$rtable.$colA => $colA_dtable.$colA\";\n".
    "d2rq:join \"$colB_dtable.$colB <= $rtable.$colB\";\n".
    ".\n\n";
}

print $fh "\n# Hand added mappings suggested by James Reidy
#r_component_geographic_affiliation | ignore

#
# for table: r_pa_geographic_affiliation
#  paid -> d_performing_arts | affid -> d_pa_geographic_affiliation
#
map:r_pa_to_geographic_affiliation a d2rq:PropertyBridge;
  d2rq:belongsToClassMap map:d_performing_arts;
  d2rq:property vocab:pa_to_geographic_affiliation;
  d2rq:refersToClassMap map:d_pa_geographic_affiliation;
  d2rq:join \"r_pa_geographic_affiliation.paid => d_performing_arts.paid\";
  d2rq:join \"d_pa_geographic_affiliation.affid <= r_pa_geographic_affiliation.affid\";
.
#
# for table r_person_geographic_affiliation
#  personid -> d_person | affid -> d_person_geographic_affiliation
#
map:r_person_to_geographic_affiliation a d2rq:PropertyBridge;
  d2rq:belongsToClassMap map:d_person;
  d2rq:property vocab:person_to_geographic_affiliation;
  d2rq:refersToClassMap map:d_person_geographic_affiliation;
  d2rq:join \"r_person_geographic_affiliation.personid => d_person.personid\";
  d2rq:join \"d_person_geographic_affiliation.affid <= r_person_geographic_affiliation.affid\";
.
#
# for table r_piece_affiliation
#  pieceid -> d_piece | affid -> d_piece_affiliation
#
map:r_piece_to_piece_affiliation a d2rq:PropertyBridge;
  d2rq:belongsToClassMap map:d_piece;
  d2rq:property vocab:piece_to_piece_affiliation;
  d2rq:refersToClassMap map:d_piece_affiliation;
  d2rq:join \"r_piece_affiliation.pieceid => d_piece.pieceid\";
  d2rq:join \"d_piece_affiliation.affid <= r_piece_affiliation.affid\";
.
#
# for table r_place_affiliation
#  placeid -> d_place | affid -> d_place_affiliation
#
map:r_place_to_place_affiliation a d2rq:PropertyBridge;
  d2rq:belongsToClassMap map:d_place;
  d2rq:property vocab:place_to_place_affiliation;
  d2rq:refersToClassMap map:d_place_affiliation;
  d2rq:join \"r_place_affiliation.placeid => d_place.placeid\";
  d2rq:join \"d_place_affiliation.affid <= r_place_affiliation.affid\";
.
# t_place_affiliation | ignore
";

print $fh q(

#
# Start of Shinwoo's dynamic properites
#
map:r_biblio_author a d2rq:PropertyBridge;
    d2rq:belongsToClassMap map:d_biblio_author;
    d2rq:dynamicProperty "http://r_biblio_author/@@d_biblio_authortype.authortype@@";
    d2rq:refersToClassMap map:d_bibliography;
    d2rq:join "d_biblio_author.authorid <= r_biblio_author.authorid";
    d2rq:join "d_bibliography.biblioid <= r_biblio_author.biblioid";
    d2rq:join "d_biblio_authortype.authortypeid <= r_biblio_author.authortypeid";
    .
map:r_biblio_author_partial a d2rq:PropertyBridge;
    d2rq:belongsToClassMap map:d_biblio_author;
    d2rq:property vocab:r_biblio_author;
    d2rq:condition "r_biblio_author.authortypeid is null";
    d2rq:refersToClassMap map:d_bibliography;
    d2rq:join "d_biblio_author.authorid <= r_biblio_author.authorid";
    d2rq:join "d_bibliography.biblioid <= r_biblio_author.biblioid";
    .


map:r_component_person_associated a d2rq:PropertyBridge;
    d2rq:belongsToClassMap map:d_person;
    d2rq:dynamicProperty "http://r_component_person_associated/@@d_function.function@@";
    d2rq:refersToClassMap map:d_component;
    d2rq:join "d_person.personid <= r_component_person_associated.personid";
    d2rq:join "d_component.componentid <= r_component_person_associated.componentid";
    d2rq:join "d_function.functionid <= r_component_person_associated.functionid";
    .
map:r_component_person_associated_partial a d2rq:PropertyBridge;
    d2rq:belongsToClassMap map:d_person;
    d2rq:property vocab:r_component_person_associated;
    d2rq:condition "r_component_person_associated.functionid is null";
    d2rq:refersToClassMap map:d_component;
    d2rq:join "d_person.personid <= r_component_person_associated.personid";
    d2rq:join "d_component.componentid <= r_component_person_associated.componentid";
    .
map:r_component_person_represented a d2rq:PropertyBridge;
    d2rq:belongsToClassMap map:d_person;
    d2rq:dynamicProperty "http://r_component_person_represented/@@d_function.function@@";
    d2rq:refersToClassMap map:d_component;
    d2rq:join "d_person.personid <= r_component_person_represented.personid";
    d2rq:join "d_component.componentid <= r_component_person_represented.componentid";
    d2rq:join "d_function.functionid <= r_component_person_represented.functionid";
    .
map:r_component_person_represented_partial a d2rq:PropertyBridge;
    d2rq:belongsToClassMap map:d_person;
    d2rq:property vocab:r_component_person_represented;
    d2rq:condition "r_component_person_represented.functionid is null";
    d2rq:refersToClassMap map:d_component;
    d2rq:join "d_person.personid <= r_component_person_represented.personid";
    d2rq:join "d_component.componentid <= r_component_person_represented.componentid";
    .
map:r_digdoc_person a d2rq:PropertyBridge;
    d2rq:belongsToClassMap map:d_person;
    d2rq:dynamicProperty "http://r_digdoc_person/@@d_function.function@@";
    d2rq:refersToClassMap map:d_digdoc;
    d2rq:join "d_person.personid <= r_digdoc_person.personid";
    d2rq:join "d_digdoc.digdocid <= r_digdoc_person.digdocid";
    d2rq:join "d_function.functionid <= r_digdoc_person.functionid";
    .
map:r_digdoc_person_partial a d2rq:PropertyBridge;
    d2rq:belongsToClassMap map:d_person;
    d2rq:property vocab:r_digdoc_person;
    d2rq:condition "r_digdoc_person.functionid is null";
    d2rq:refersToClassMap map:d_digdoc;
    d2rq:join "d_person.personid <= r_digdoc_person.personid";
    d2rq:join "d_digdoc.digdocid <= r_digdoc_person.digdocid";
    .
map:r_pa_group_person a d2rq:PropertyBridge;
    d2rq:belongsToClassMap map:d_person;
    d2rq:dynamicProperty "http://r_pa_group_person/@@d_function.function@@";
    d2rq:refersToClassMap map:d_pa_group;
    d2rq:join "d_person.personid <= r_pa_group_person.personid";
    d2rq:join "d_pa_group.pagroupid <= r_pa_group_person.pagroupid";
    d2rq:join "d_function.functionid <= r_pa_group_person.functionid";
    .
map:r_pa_group_person_partial a d2rq:PropertyBridge;
    d2rq:belongsToClassMap map:d_person;
    d2rq:property vocab:r_pa_group_person;
    d2rq:condition "r_pa_group_person.functionid is null";
    d2rq:refersToClassMap map:d_pa_group;
    d2rq:join "d_person.personid <= r_pa_group_person.personid";
    d2rq:join "d_pa_group.pagroupid <= r_pa_group_person.pagroupid";
    .
map:r_pa_person a d2rq:PropertyBridge;
    d2rq:belongsToClassMap map:d_person;
    d2rq:dynamicProperty "http://r_pa_person/@@d_function.function@@";
    d2rq:refersToClassMap map:d_performing_arts;
    d2rq:join "d_person.personid <= r_pa_person.personid";
    d2rq:join "d_performing_arts.paid <= r_pa_person.paid";
    d2rq:join "d_function.functionid <= r_pa_person.functionid";
    .
map:r_pa_person_partial a d2rq:PropertyBridge;
    d2rq:belongsToClassMap map:d_person;
    d2rq:property vocab:r_pa_person;
    d2rq:condition "r_pa_person.functionid is null";
    d2rq:refersToClassMap map:d_performing_arts;
    d2rq:join "d_person.personid <= r_pa_person.personid";
    d2rq:join "d_performing_arts.paid <= r_pa_person.paid";
    .
map:r_piece_creator a d2rq:PropertyBridge;
    d2rq:belongsToClassMap map:d_person;
    d2rq:dynamicProperty "http://r_piece_creator/@@d_function.function@@";
    d2rq:refersToClassMap map:d_piece;
    d2rq:join "d_person.personid <= r_piece_creator.personid";
    d2rq:join "d_piece.pieceid <= r_piece_creator.pieceid";
    d2rq:join "d_function.functionid <= r_piece_creator.functionid";
    .
map:r_piece_creator_partial a d2rq:PropertyBridge;
    d2rq:belongsToClassMap map:d_person;
    d2rq:property vocab:r_piece_creator;
    d2rq:condition "r_piece_creator.functionid is null";
    d2rq:refersToClassMap map:d_piece;
    d2rq:join "d_person.personid <= r_piece_creator.personid";
    d2rq:join "d_piece.pieceid <= r_piece_creator.pieceid";
    .
map:r_sourceobject_person a d2rq:PropertyBridge;
    d2rq:belongsToClassMap map:d_person;
    d2rq:dynamicProperty "http://r_sourceobject_person/@@d_function.function@@";
    d2rq:refersToClassMap map:d_source_object;
    d2rq:join "d_person.personid <= r_sourceobject_person.personid";
    d2rq:join "d_source_object.sourceobjectid <= r_sourceobject_person.sourceobjectid";
    d2rq:join "d_function.functionid <= r_sourceobject_person.functionid";
    .
map:r_sourceobject_person_partial a d2rq:PropertyBridge;
    d2rq:belongsToClassMap map:d_person;
    d2rq:property vocab:r_sourceobject_person;
    d2rq:condition "r_sourceobject_person.functionid is null";
    d2rq:refersToClassMap map:d_source_object;
    d2rq:join "d_person.personid <= r_sourceobject_person.personid";
    d2rq:join "d_source_object.sourceobjectid <= r_sourceobject_person.sourceobjectid";
    .

map:r_performance_piece a d2rq:PropertyBridge;
    d2rq:belongsToClassMap map:d_performance;
    d2rq:dynamicProperty "http://r_performance_piece/@@d_structure_division.structuredivision@@";
    d2rq:refersToClassMap map:d_piece;
    d2rq:join "d_performance.performanceid <= r_performance_piece.performanceid";
    d2rq:join "d_piece.pieceid <= r_performance_piece.pieceid";
    d2rq:join "d_structure_division.structuredivisionid <= r_performance_piece.structuredivisionid";
    .
map:r_performance_piece_partial a d2rq:PropertyBridge;
    d2rq:belongsToClassMap map:d_performance;
    d2rq:property vocab:r_performance_piece;
    d2rq:condition "r_performance_piece.structuredivisionid is null";
    d2rq:refersToClassMap map:d_piece;
    d2rq:join "d_performance.performanceid <= r_performance_piece.performanceid";
    d2rq:join "d_piece.pieceid <= r_performance_piece.pieceid";
    .
# End of Shinwoo's dynamic properites
);

close $fh;


my $notes="

TODO: drop junk tables
c_aaa_test etc.

TODO: ignore views

TODO: make sure we have a d_pa_geographic_affiliation mapping

TODO: Collections
The 2004-04-28 diagram indicates a set/subset relation for digital objects.
See if we can pull this out of r_digdoc_collection or somethinig.

TODO: Type tables:

There are some type tables that need to be considered and added to d_ tables as rdf:types.

 d_place_type with columns  typeid,type
 d_pa_group_altnametype with columns  typeid,type
 d_person_affiliation with columns  affid,affiliation
 d_piece_relation_type with columns  typeid,type
 d_production_type with columns  typeid,type
 d_component_type with columns  typeid,type

TODO: Affiliations:

There seems to be a set of affiliations which are a sort of relationship. We should work on these.

 d_pa_geographic_affiliation with columns  affid,affiliation,latitude,longitude
 d_person_affiliation with columns  affid,affiliation
 d_person_geographic_affiliation with columns  affid,affiliation,latitude,longitude
 d_piece_affiliation with columns  affid,affiliation
 d_place_affiliation with columns  affid,affiliation
 d_component_geographic_affiliation with columns  affid,affiliation,latitude,longitude

TODO: Alt names:

There seems to be an altname feature. It might not be critical for this prototype.

";
