package Hailo::Storage::DBD;
use 5.010;
use Any::Moose;
use Any::Moose 'X::Types::'.any_moose() => [qw<ArrayRef HashRef Int Str Bool>];
BEGIN {
    return unless Any::Moose::moose_is_preferred();
    require MooseX::StrictConstructor;
    MooseX::StrictConstructor->import;
}
use DBI;
use Data::Section qw(-setup);
use Template;
use namespace::clean -except => [ qw(meta
                                     section_data
                                     section_data_names
                                     merged_section_data
                                     merged_section_data_names) ];

has dbd => (
    isa           => Str,
    is            => 'ro',
    lazy_build    => 1,
    documentation => "The DBD::* driver we're using",
);

has dbd_options => (
    isa           => HashRef,
    is            => 'ro',
    lazy_build    => 1,
    documentation => 'Options passed as the last argument to DBI->connect()',
);

sub _build_dbd_options {
    my ($self) = @_;
    return {
        RaiseError => 1
    };
}

has dbh => (
    isa           => 'DBI::db',
    is            => 'ro',
    lazy_build    => 1,
    documentation => 'Our DBD object',
);

sub _build_dbh {
    my ($self) = @_;
    my $dbd_options = $self->dbi_options;

    return DBI->connect($self->dbi_options);
};

has dbi_options => (
    isa           => ArrayRef,
    is            => 'ro',
    auto_deref    => 1,
    lazy_build    => 1,
    documentation => 'Options passed to DBI->connect()',
);

sub _build_dbi_options {
    my ($self) = @_;
    my $dbd = $self->dbd;
    my $dbd_options = $self->dbd_options;
    my $db = $self->brain // '';

    my @options = (
        "dbi:$dbd:dbname=$db",
        '',
        '',
        $dbd_options,
    );

    return \@options;
}

has _engaged => (
    isa           => Bool,
    is            => 'rw',
    default       => 0,
    documentation => 'Have we done setup work to get this database going?',
);

has sth => (
    isa        => HashRef,
    is         => 'ro',
    lazy_build => 1,
    documentation => 'A HashRef of prepared DBI statement handles',
);

# our statement handlers
sub _build_sth {
    my ($self) = @_;
    my ($sections, $prefix) = $self->_sth_sections_static();

    return $self->_prepare_sth($sections, $prefix);
}

has _boundary_token_id => (
    isa => Int,
    is  => 'rw',
);

# bootstrap the database
sub _engage {
    my ($self) = @_;

    if ($self->_exists_db) {
        $self->sth->{get_order}->execute();
        my $order = $self->sth->{get_order}->fetchrow_array();
        $self->order($order);

        $self->sth->{token_id}->execute(0, '');
        my $id = $self->sth->{token_id}->fetchrow_array;
        $self->_boundary_token_id($id);
    }
    else {
        $self->_create_db();

        my $order = $self->order;
        $self->sth->{set_order}->execute($order);

        $self->sth->{add_token}->execute(0, '');
        $self->sth->{last_token_rowid}->execute();
        my $id = $self->sth->{last_token_rowid}->fetchrow_array();
        $self->_boundary_token_id($id);
    }

    # prepare SQL statements which depend on the Markov order
    my ($sections, $prefix) = $self->_sth_sections_dynamic();
    my $sth = $self->_prepare_sth($sections, $prefix);
    while (my ($query, $st) = each %$sth) {
        $self->sth->{$query} = $st;
    }

    $self->_engaged(1);

    return;
}

sub start_training {
    my ($self) = @_;
    $self->_engage() if !$self->_engaged;
    $self->start_learning();
    return;
}

sub stop_training {
    my ($self) = @_;
    $self->stop_learning();
    return;
}

sub start_learning {
    my ($self) = @_;
    $self->_engage() if !$self->_engaged;

    # start a transaction
    $self->dbh->begin_work;
    return;
}

sub stop_learning {
    my ($self) = @_;
    # finish a transaction
    $self->dbh->commit;
    return;
}

# return some statistics
sub totals {
    my ($self) = @_;
    $self->_engage() if !$self->_engaged;

    $self->sth->{token_total}->execute();
    my $token = $self->sth->{token_total}->fetchrow_array - 1;
    $self->sth->{expr_total}->execute();
    my $expr = $self->sth->{expr_total}->fetchrow_array // 0;
    $self->sth->{prev_total}->execute();
    my $prev = $self->sth->{prev_total}->fetchrow_array // 0;
    $self->sth->{next_total}->execute();
    my $next = $self->sth->{next_total}->fetchrow_array // 0;

    return $token, $expr, $prev, $next;
}

## Soup to spawn the database itself / create statement handles
sub _create_db {
    my ($self) = @_;
    my @statements = $self->_get_create_db_sql;

    for (@statements) {
        $self->dbh->do($_);
    }

    return;
}

sub _get_create_db_sql {
    my ($self) = @_;
    my $sql;

    for my $section (qw(info token expr next_token prev_token indexes)) {
        my $template = $self->section_data("table_$section");
        Template->new->process(
            $template,
            {
                columns => join(', ', map { "token${_}_id" } 0 .. $self->order-1),
                orders  => [ 0 .. $self->order-1 ],
                dbd     => $self->dbd,
            },
            \$sql,
        );
    }

    return ($sql =~ /\s*(.*?);/gs);
}

# create statement handle objects
sub _prepare_sth {
    my ($self, $sections, $prefix) = @_;

    my %state;
    while (my ($name, $options) = each %$sections) {
        my $section = $options->{section} // $name;
        my %options = %{ $options->{options} // {} };
        my $template = $self->section_data("$prefix$section");
        my $sql;
        Template->new->process(
            $template,
            {
                orders => [ 0 .. $self->order-1 ],
                dbd    => $self->dbd,
                %options,
            },
            \$sql,
        );
        $state{$name} = $sql;
    }

    $state{$_} = $self->dbh->prepare($state{$_}) for keys %state;
    return \%state;
}

# return SQL statements which are not dependent on the Markov order
sub _sth_sections_static {
    my ($self) = @_;
    my %sections;
    my $prefix = 'static_query_';

    # () sections are magical
    my @plain_sections = grep { /^$prefix/ and not /\(.*?\)/ } $self->section_data_names;
    s[^$prefix][] for @plain_sections;

    $sections{$_} = undef for @plain_sections;

    for my $np (qw(next_token prev_token)) {
        for my $ciag (qw(count inc add get)) {
            $sections{$np . '_' . $ciag} = {
                section => "(next_token|prev_token)_$ciag",
                options => { table => $np },
            };
        }
    }

    return \%sections, $prefix;;
}

# return SQL statements which are dependent on the Markov order
sub _sth_sections_dynamic {
    my ($self) = @_;
    my %sections;
    my $prefix = 'dynamic_query_';

    # () sections are magical
    my @plain_sections = grep { /^$prefix/ and not /\(.*?\)/ } $self->section_data_names;
    s[^$prefix][] for @plain_sections;

    $sections{$_} = undef for @plain_sections;

    for my $order (0 .. $self->order-1) {
        $sections{"expr_by_token${order}_id"} = {
            section => 'expr_by_token(NUM)_id',
            options => { column => "token${order}_id" },
        };
    }

    {
        my @columns = map { "token${_}_id" } 0 .. $self->order-1;
        my @ids = join(', ', ('?') x @columns);
        $sections{add_expr} = {
            section => '(add_expr)',
            options => {
                columns => join(', ', @columns),
                ids     => join(', ', @ids),
            }
        }
    }

    return \%sections, $prefix;
}

__PACKAGE__->meta->make_immutable;

=encoding utf8

=head1 NAME

Hailo::Storage::DBD - A base class for L<Hailo> DBD
L<storage|Hailo::Role::Storage> backends

=head1 METHODS

The following methods must to be implemented by subclasses:

=head2 C<_build_dbd>

Should return the name of the database driver (e.g. 'SQLite') which will be
passed to L<DBI|DBI>.

=head2 C<_build_dbd_options>

Subclasses can override this method to add options of their own. E.g:

    override _build_dbd_options => sub {
        return {
            %{ super() },
            sqlite_unicode => 1,
        };
    };

=head2 C<_exists_db>

Should return a true value if the database has already been created.

=head1 AUTHOR

E<AElig>var ArnfjE<ouml>rE<eth> Bjarmason <avar@cpan.org>

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=head1 LICENSE AND COPYRIGHT

Copyright 2010 E<AElig>var ArnfjE<ouml>rE<eth> Bjarmason and
Hinrik E<Ouml>rn SigurE<eth>sson

This program is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__DATA__
__[ table_info ]__
CREATE TABLE info (
    attribute [% SWITCH dbd %]
                  [% CASE 'mysql' %]TEXT NOT NULL,
                  [% CASE DEFAULT %]TEXT NOT NULL PRIMARY KEY,
              [% END %]
    text      TEXT NOT NULL
);
__[ table_token ]__
CREATE TABLE token (
    id   [% SWITCH dbd %]
            [% CASE 'Pg'    %]SERIAL UNIQUE,
            [% CASE 'mysql' %]INTEGER PRIMARY KEY AUTO_INCREMENT,
            [% CASE DEFAULT %]INTEGER PRIMARY KEY AUTOINCREMENT,
         [% END %]
    spacing INTEGER NOT NULL,
    text [% IF dbd == 'mysql' %] VARCHAR(255) [% ELSE %] TEXT [% END %] NOT NULL,
    count INTEGER NOT NULL
);
__[ table_expr ]__
CREATE TABLE expr (
    id  [% SWITCH dbd %]
            [% CASE 'Pg'    %]SERIAL UNIQUE
            [% CASE 'mysql' %]INTEGER PRIMARY KEY AUTO_INCREMENT
            [% CASE DEFAULT %]INTEGER PRIMARY KEY AUTOINCREMENT
        [% END %],
[% FOREACH i IN orders %]
    token[% i %]_id INTEGER NOT NULL REFERENCES token (id)[% UNLESS loop.last %],[% END %]
[% END %]
);
__[ table_next_token ]__
CREATE TABLE next_token (
    id       [% SWITCH dbd %]
                 [% CASE 'Pg'    %]SERIAL UNIQUE,
                 [% CASE 'mysql' %]INTEGER PRIMARY KEY AUTO_INCREMENT,
                 [% CASE DEFAULT %]INTEGER PRIMARY KEY AUTOINCREMENT,
             [% END %]
    expr_id  INTEGER NOT NULL REFERENCES expr (id),
    token_id INTEGER NOT NULL REFERENCES token (id),
    count    INTEGER NOT NULL
);
__[ table_prev_token ]__
CREATE TABLE prev_token (
    id       [% SWITCH dbd %]
                 [% CASE 'Pg'    %]SERIAL UNIQUE,
                 [% CASE 'mysql' %]INTEGER PRIMARY KEY AUTO_INCREMENT,
                 [% CASE DEFAULT %]INTEGER PRIMARY KEY AUTOINCREMENT,
             [% END %]
    expr_id  INTEGER NOT NULL REFERENCES expr (id),
    token_id INTEGER NOT NULL REFERENCES token (id),
    count    INTEGER NOT NULL
);
__[ table_indexes ]__
CREATE INDEX token_text on token (text);
[% FOREACH i IN orders %]
    CREATE INDEX expr_token[% i %]_id on expr (token[% i %]_id);
[% END %]
CREATE INDEX expr_token_ids on expr ([% columns %]);
CREATE INDEX next_token_expr_id ON next_token (expr_id);
CREATE INDEX prev_token_expr_id ON prev_token (expr_id);
__[ static_query_get_order ]__
SELECT text FROM info WHERE attribute = 'markov_order';
__[ static_query_set_order ]__
INSERT INTO info (attribute, text) VALUES ('markov_order', ?);
__[ static_query_token_total ]__
SELECT COUNT(id) FROM token;
__[ static_query_expr_total ]__
SELECT COUNT(id) FROM expr;
__[ static_query_prev_total ]__
SELECT COUNT(id) FROM prev_token;
__[ static_query_next_total ]__
SELECT COUNT(id) FROM next_token;
__[ static_query_random_expr ]__
SELECT * from expr
[% SWITCH dbd %]
    [% CASE 'Pg'    %]WHERE id >= (random()*id+1)::int
    [% CASE 'mysql' %]WHERE id >= (abs(rand()) % (SELECT max(id) FROM expr))
    [% CASE DEFAULT %]WHERE id >= (abs(random()) % (SELECT max(id) FROM expr))
[% END %]
  LIMIT 1;
__[ static_query_token_id ]__
SELECT id FROM token WHERE spacing = ? AND text = ?;
__[ static_query_token_info ]__
SELECT spacing, text FROM token WHERE id = ?;
__[ static_query_token_similar ]__
SELECT id, spacing FROM token WHERE text = ?
[% SWITCH dbd %]
    [% CASE 'mysql'  %]ORDER BY RAND()   LIMIT 1;
    [% CASE DEFAULT  %]ORDER BY RANDOM() LIMIT 1;
[% END %]
__[ static_query_add_token ]__
INSERT INTO token (spacing, text, count) VALUES (?, ?, 0)
[% IF dbd == 'Pg' %] RETURNING id[% END %];
__[ static_query_inc_token_count ]__
UPDATE token SET count = count + 1 WHERE id = ?;
__[ static_query_last_expr_rowid ]_
SELECT id FROM expr ORDER BY id DESC LIMIT 1;
__[ static_query_last_token_rowid ]__
SELECT id FROM token ORDER BY id DESC LIMIT 1;
__[ static_query_(next_token|prev_token)_count ]__
SELECT count FROM [% table %] WHERE expr_id = ? AND token_id = ?;
__[ static_query_(next_token|prev_token)_inc ]__
UPDATE [% table %] SET count = count + 1 WHERE expr_id = ? AND token_id = ?
__[ static_query_(next_token|prev_token)_add ]__
INSERT INTO [% table %] (expr_id, token_id, count) VALUES (?, ?, 1);
__[ static_query_(next_token|prev_token)_get ]__
SELECT token_id, count FROM [% table %] WHERE expr_id = ?;
__[ static_query_token_count ]__
SELECT count FROM token WHERE id = ?;
__[ dynamic_query_(add_expr) ]__
INSERT INTO expr ([% columns %]) VALUES ([% ids %])
[% IF dbd == 'Pg' %] RETURNING id[% END %];
__[ dynamic_query_expr_by_token(NUM)_id ]__
SELECT * FROM expr WHERE [% column %] = ?
[% SWITCH dbd %]
    [% CASE 'mysql'  %]ORDER BY RAND()   LIMIT 1;
    [% CASE DEFAULT  %]ORDER BY RANDOM() LIMIT 1;
[% END %]
__[ dynamic_query_expr_id ]__
SELECT id FROM expr WHERE
[% FOREACH i IN orders %]
    token[% i %]_id = ? [% UNLESS loop.last %] AND [% END %]
[% END %]
