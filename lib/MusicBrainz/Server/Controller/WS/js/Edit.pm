package MusicBrainz::Server::Controller::WS::js::Edit;
use DBDefs;
use File::Spec::Functions qw( catdir );
use JSON::Any;
use List::MoreUtils qw( any );
use Moose;
use MusicBrainz::Server::Constants qw(
    $EDIT_RELEASE_CREATE
    $EDIT_RELEASE_EDIT
    $EDIT_RELEASE_ADDRELEASELABEL
    $EDIT_RELEASE_ADD_ANNOTATION
    $EDIT_RELEASE_DELETERELEASELABEL
    $EDIT_RELEASE_EDITRELEASELABEL
    $EDIT_RELEASEGROUP_CREATE
    $EDIT_MEDIUM_CREATE
    $EDIT_MEDIUM_EDIT
    $EDIT_MEDIUM_DELETE
    $EDIT_MEDIUM_ADD_DISCID
    $EDIT_RECORDING_EDIT
    $EDIT_RELEASE_REORDER_MEDIUMS
    $EDIT_RELATIONSHIP_CREATE
    $EDIT_RELATIONSHIP_EDIT
    $EDIT_RELATIONSHIP_DELETE
    $AUTO_EDITOR_FLAG
);
use MusicBrainz::Server::Data::Utils qw(
    type_to_model
    model_to_type
    partial_date_to_hash
);
use MusicBrainz::Server::Edit::Utils qw( boolean_from_json );
use MusicBrainz::Server::Translation qw( l );
use MusicBrainz::Server::Validation qw( is_guid is_valid_url );
use Readonly;
use Scalar::Util qw( looks_like_number );
use Try::Tiny;
use URI;
use aliased 'MusicBrainz::Server::Entity::ArtistCredit';
use aliased 'MusicBrainz::Server::Entity::Track';
use aliased 'MusicBrainz::Server::WebService::JSONSerializer';
BEGIN { extends 'MusicBrainz::Server::Controller' }


Readonly our $ERROR_NOT_LOGGED_IN => 1;
Readonly our $ERROR_NON_EXISTENT_ENTITIES => 2;


our $TT = Template->new(
    INCLUDE_PATH => catdir(DBDefs->MB_SERVER_ROOT, 'root'),

    %{ MusicBrainz::Server->config->{'View::Default'} }
);

our $JSON = JSON::Any->new( utf8 => 0 );


sub load_entity_prop {
    my ($loader, $data, $prop, $model) = @_;

    $loader->($data->{$prop}, $model, sub { $data->{$prop} = shift });
}


our $data_processors = {

    $EDIT_RELEASE_CREATE => \&process_artist_credit,

    $EDIT_RELEASE_EDIT => sub {
        my ($c, $loader, $data) = @_;

        process_artist_credit($c, $loader, $data);

        load_entity_prop($loader, $data, 'to_edit', 'Release');
    },

    $EDIT_RELEASE_ADDRELEASELABEL => sub {
        my ($c, $loader, $data) = @_;

        load_entity_prop($loader, $data, 'release', 'Release');
        load_entity_prop($loader, $data, 'label', 'Label');
    },

    $EDIT_RELEASE_ADD_ANNOTATION => sub {
        my ($c, $loader, $data) = @_;

        load_entity_prop($loader, $data, 'entity', 'Release');
    },

    $EDIT_RELEASE_DELETERELEASELABEL => sub {
        my ($c, $loader, $data) = @_;

        load_entity_prop($loader, $data, 'release_label', 'ReleaseLabel');
    },

    $EDIT_RELEASE_EDITRELEASELABEL => sub {
        my ($c, $loader, $data) = @_;

        load_entity_prop($loader, $data, 'release_label', 'ReleaseLabel');
        load_entity_prop($loader, $data, 'label', 'Label');
    },

    $EDIT_MEDIUM_CREATE => sub {
        my ($c, $loader, $data) = @_;

        process_medium($c, $loader, $data);

        load_entity_prop($loader, $data, 'release', 'Release');
    },

    $EDIT_MEDIUM_EDIT => sub {
        my ($c, $loader, $data) = @_;

        process_medium($c, $loader, $data);

        load_entity_prop($loader, $data, 'to_edit', 'Medium');
    },

    $EDIT_MEDIUM_DELETE => sub {
        my ($c, $loader, $data) = @_;

        load_entity_prop($loader, $data, 'medium', 'Medium');
    },

    $EDIT_MEDIUM_ADD_DISCID => sub {
        my ($c, $loader, $data) = @_;

        load_entity_prop($loader, $data, 'release', 'Release');
    },

    $EDIT_RECORDING_EDIT => sub {
        my ($c, $loader, $data) = @_;

        process_artist_credit($c, $loader, $data);

        load_entity_prop($loader, $data, 'to_edit', 'Recording');
    },

    $EDIT_RELATIONSHIP_CREATE => \&process_relationship,

    $EDIT_RELATIONSHIP_EDIT => \&process_relationship,

    $EDIT_RELEASE_REORDER_MEDIUMS => sub {
        my ($c, $loader, $data) = @_;

        load_entity_prop($loader, $data, 'release', 'Release');
    },

    $EDIT_RELEASEGROUP_CREATE => \&process_artist_credit,
};


sub process_artist_credits {
    my ($c, $loader, @artist_credits) = @_;

    my @artist_gids;

    for my $ac (@artist_credits) {
        my @names = @{ $ac->{names} };

        for my $name (@names) {
            my $artist = $name->{artist};

            if (!$artist->{id} && is_guid($artist->{gid}))  {
                push @artist_gids, $artist->{gid};
            }
        }
    }

    return unless @artist_gids;

    my $artists = $c->model('Artist')->get_by_gids(@artist_gids);

    for my $ac (@artist_credits) {
        my @names = @{ $ac->{names} };

        for my $name (@names) {
            my $artist = $name->{artist};
            my $gid = delete $artist->{gid};

            if ($gid and my $entity = $artists->{$gid}) {
                $artist->{id} = $entity->id;
            }
        }
    }
}

sub process_artist_credit {
    my ($c, $loader, $data) = @_;

    process_artist_credits($c, $loader, $data->{artist_credit})
        if defined $data->{artist_credit};
}

sub process_medium {
    my ($c, $loader, $data) = @_;

    return unless defined $data->{tracklist};

    my @tracks = @{ $data->{tracklist} };
    my @recording_gids = grep { $_ } map { $_->{recording_gid} } @tracks;
    my $recordings = $c->model('Recording')->get_by_gids(@recording_gids);

    my @track_acs = grep { $_ } map { $_->{artist_credit} } @tracks;
    process_artist_credits($c, $loader, @track_acs) if scalar @track_acs;

    my $process_track = sub {
        my $track = shift;
        my $recording_gid = delete $track->{recording_gid};

        if (defined $recording_gid) {
            $track->{recording} = $recordings->{$recording_gid};
            $track->{recording_id} = $recordings->{$recording_gid}->id;
        }

        delete $track->{id} unless defined $track->{id};

        my $ac = $track->{artist_credit};
        $track->{artist_credit} = ArtistCredit->from_array($ac->{names}) if $ac;

        return Track->new(%$track);
    };

    $data->{tracklist} = [ map { $process_track->($_) } @tracks ];
}

sub process_relationship {
    my ($c, $loader, $data, $previewing) = @_;

    $data->{entity0} = $data->{entities}->[0];
    $data->{entity1} = $data->{entities}->[1];

    $data->{begin_date} = delete $data->{beginDate} // {};
    $data->{end_date} = delete $data->{endDate} // {};
    $data->{ended} = boolean_from_json($data->{ended});

    delete $data->{id};
    delete $data->{linkTypeID};
    delete $data->{entities};

    for my $prop ("entity0", "entity1") {
        my $entity_data = $data->{$prop};

        if ($entity_data) {
            my $name = $entity_data->{name};
            my $model = type_to_model($entity_data->{entityType});

            if ($model eq 'URL') {
                my $url = URI->new($name)->canonical;

                my $url_string = $url->as_string;
                my $url_scheme = $url->scheme;

                die "invalid URL: $url_string" unless is_valid_url($url_string);
                die "unsupported URL protocol: $url_scheme" unless lc($url_scheme) =~ m/^(https?|ftp)$/;

                $name = $entity_data->{name} = $url_string;
            }

            if ($previewing && !$entity_data->{gid}) {
                my $entity_class = "MusicBrainz::Server::Entity::$model";
                my ($entity) = $model eq "URL" ? $c->model('URL')->find_by_url($name) : ();

                $data->{$prop} = $entity // $entity_class->new(name => $name);
            } elsif ($model eq "URL") {
                $data->{$prop} = $c->model('URL')->find_or_insert($name);
            } else {
                $loader->($entity_data->{gid}, $model, sub { $data->{$prop} = shift });
            }
        } elsif ($data->{relationship}) {
            $data->{$prop} = $data->{relationship}->$prop;
        }
    }
}

sub detach_with_error {
    my ($c, $error) = @_;

    $c->res->body($JSON->encode({ error => $error }));
    $c->res->status(400);
    $c->detach;
}

sub critical_error {
    my ($c, $error) = @_;

    $c->error($error);
    $c->stash->{error_body_in_stash} = 1;
    $c->stash->{body} = $JSON->encode({ error => $error });
    $c->stash->{status} = 400;
}

sub get_request_body {
    my $c = shift;

    my $body = $c->req->body;

    detach_with_error($c, 'empty request') unless $body;

    my $json_string = <$body>;
    my $decoded_object = eval { $JSON->decode($json_string) };

    detach_with_error($c, "$@") if $@;

    return $decoded_object;
}

sub process_edits {
    my ($c, $edits, $previewing) = @_;

    my $ids_to_load = {};
    my $gids_to_load = {};
    my $relationships_to_load = {};
    my @link_types_to_load;
    my @props_to_load;

    for my $edit (@$edits) {
        my $edit_type = $edit->{edit_type};

        if ($edit_type == $EDIT_RELATIONSHIP_CREATE) {
            die 'missing linkTypeID' unless $edit->{linkTypeID};

            push @link_types_to_load, $edit;
        }

        if ($edit_type == $EDIT_RELATIONSHIP_EDIT ||
            $edit_type == $EDIT_RELATIONSHIP_DELETE) {

            my $type0 = $edit->{entities}->[0]->{entityType} or die 'missing entityType';
            my $type1 = $edit->{entities}->[1]->{entityType} or die 'missing entityType';
            my $id = $edit->{id} or die 'missing relationship id';

            # Only one edit per relationship is supported.
            ($relationships_to_load->{"$type0-$type1"} //= {})->{ $id } = $edit;

            push @link_types_to_load, $edit if $edit->{linkTypeID};
        }
    }

    my @loaded_relationships;

    while (my ($types, $edits) = each %$relationships_to_load) {
        my ($type0, $type1) = split /-/, $types;

        my $relationships_by_id = $c->model('Relationship')->get_by_ids(
           $type0, $type1, keys %$edits
        );

        my @relationships = values %$relationships_by_id;
        $c->model('Link')->load(@relationships);

        while (my ($id, $edit) = each %$edits) {
            $edit->{relationship} = $relationships_by_id->{$id};
        }

        push @loaded_relationships, @relationships;
    }

    my $link_types = $c->model('LinkType')->get_by_ids(
        ( map { $_->{linkTypeID} } @link_types_to_load ),
        ( map { $_->link->type_id } @loaded_relationships ),
    );

    $_->{link_type} = $link_types->{ $_->{linkTypeID} } for @link_types_to_load;
    $_->link->type($link_types->{ $_->link->type_id }) for @loaded_relationships;

    $c->model('Relationship')->load_entities(@loaded_relationships);

    my $loader = sub {
        my ($id, $model, $setter) = @_;

        if (looks_like_number($id)) {
            push @{ $ids_to_load->{$model} //= [] }, $id;
        } elsif (is_guid($id)) {
            push @{ $gids_to_load->{$model} //= [] }, $id;
        } elsif (!defined($id) && $previewing) {
            return;
        } else {
            die "unknown $model id: $id";
        }

        push @props_to_load, [$id, $model, $setter];
    };

    for my $edit (@$edits) {
        my $processor = $data_processors->{$edit->{edit_type}};
        $processor->($c, $loader, $edit, $previewing) if $processor;
    }

    my %loaded_entities = (
        ( map { $_ => $c->model($_)->get_by_ids(@{ $ids_to_load->{$_} }) } keys %$ids_to_load ),
        ( map { $_ => $c->model($_)->get_by_gids(@{ $gids_to_load->{$_} }) } keys %$gids_to_load ),
    );

    my @non_existent_entities;

    for (@props_to_load) {
        my ($id, $model, $setter) = @$_;

        unless ($setter->($loaded_entities{$model}->{$id})) {
            push @non_existent_entities, {
                type => model_to_type($model),
                is_guid($id) ? ( gid => $id ) : ( id => $id ),
            };
        }
    }

    if (@non_existent_entities) {
        die {
            errorCode => $ERROR_NON_EXISTENT_ENTITIES,
            entities => \@non_existent_entities
        };
    }
}

sub create_edits {
    my ($self, $c, $data, $previewing) = @_;

    my $privs = $c->user->privileges;

    if ($c->user->is_auto_editor && !$data->{asAutoEditor}) {
        $privs &= ~$AUTO_EDITOR_FLAG;
    }

    try {
        process_edits($c, $data->{edits}, $previewing);
    }
    catch {
        detach_with_error($c, $_);
    };

    my $action = $previewing ? 'preview' : 'create';

    return map {
        my $opts = $_;
        my $edit;

        try {
            if ($opts->{edit_type} == $EDIT_RELATIONSHIP_CREATE) {
                my $link_type = $opts->{link_type};

                MusicBrainz::Server::Edit::Exceptions::NoChanges->throw
                    if $c->model('Relationship')->exists(
                        $link_type->entity0_type, $link_type->entity1_type, {
                            link_type_id => $link_type->id,
                            entity0_id => $opts->{entity0}->id,
                            entity1_id => $opts->{entity1}->id,
                            begin_date => $opts->{begin_date},
                            end_date => $opts->{end_date},
                            ended => $opts->{ended},
                            attributes => $opts->{attributes},
                        }
                    );
            }

            $edit = $c->model('Edit')->$action(
                editor_id => $c->user->id,
                privileges => $privs,
                %$opts
            );
        }
        catch {
            unless(ref($_) eq 'MusicBrainz::Server::Edit::Exceptions::NoChanges') {
                critical_error($c, $_);
            }
        };
        $edit;
    } @{ $data->{edits} };
}

sub edit : Chained('/') PathPart('ws/js/edit') CaptureArgs(0) Edit {
    my ($self, $c) = @_;

    $c->res->content_type('application/json; charset=utf-8');

    $c->forward('/user/cookie_login') unless $c->user_exists;

    detach_with_error($c, {
        errorCode => $ERROR_NOT_LOGGED_IN,
        message => l('You must be logged in to submit edits. {url|Log in} ' .
                     'first, and then try submitting your edits again.',
                     { url => { href => $c->uri_for_action('/user/login'), target => '_blank' } }),
    }) unless $c->user_exists;
}

sub create : Chained('edit') PathPart('create') Edit {
    my ($self, $c) = @_;

    $self->submit_edits($c, get_request_body($c));
}

sub submit_edits {
    my ($self, $c, $data) = @_;

    my @edit_data = @{ $data->{edits} };
    my @edit_types = map { $_->{edit_type} } @edit_data;

    if (any { !defined($_) } @edit_types) {
        detach_with_error($c, 'edit_type required');
    }

    if (!$data->{editNote} && any { $_ == $EDIT_RELEASE_CREATE } @edit_types) {
        detach_with_error($c, 'editNote required');
    }

    my @edits;

    $c->model('MB')->with_transaction(sub {
        @edits = $self->create_edits($c, $data);

        my $edit_note = $data->{editNote};

        if ($edit_note) {
            for my $edit (grep { $_ } @edits) {
                $c->model('EditNote')->add_note($edit->id, {
                    text => $edit_note, editor_id => $c->user->id,
                });
            }
        }
    });

    my $created_entity_ids = {};
    my $created_entities = {};

    for my $edit (grep { defined $_ } @edits) {
        if ($edit->isa('MusicBrainz::Server::Edit::Generic::Create') &&
            !$edit->isa('MusicBrainz::Server::Edit::Relationship::Create')) {

            push @{ $created_entity_ids->{$edit->_create_model} //= [] }, $edit->entity_id;
        }
    }

    for my $model (keys %$created_entity_ids) {
        $created_entities->{$model} = $c->model($model)->get_by_ids(
            @{ $created_entity_ids->{$model} }
        );
    }

    my @response = map {
        my $edit = $_;
        my $response;

        if (defined $edit) {
            $response = { message => "OK" };

            if ($edit->isa('MusicBrainz::Server::Edit::Generic::Create') &&
                !$edit->isa('MusicBrainz::Server::Edit::Relationship::Create')) {

                my $model = $edit->_create_model;
                my $entity = $created_entities->{$model}->{$edit->entity_id};

                try {
                    my $js_model = "MusicBrainz::Server::Controller::WS::js::$model";
                    my $serialization_routine = $js_model->serialization_routine;

                    $js_model->_load_entities($c, $entity);

                    $response->{entity} = JSONSerializer->$serialization_routine($entity);
                    $response->{entity}->{entityType} = $js_model->type;
                }
                catch {
                    # Some entities (i.e. Mediums) don't have a WS::js model
                    # or serialization_routine. Just return their id.
                    $response->{entity} = { id => $entity->id };

                    if ($model eq 'Medium') {
                        $response->{entity}->{position} = $entity->position;
                    }
                };
            } elsif ($edit->isa("MusicBrainz::Server::Edit::Release::AddReleaseLabel")) {
                $response->{entity} = {
                    id              => $edit->entity_id,
                    labelID         => defined($edit->data->{label}) ? $edit->data->{label}{id} : undef,
                    catalogNumber   => $edit->data->{catalog_number} // undef,
                };
            }
        } else {
            $response = { message => "no changes" };
        }

        $response
    } @edits;

    $c->res->body($JSON->encode({ edits => \@response }));
}

sub preview : Chained('edit') PathPart('preview') Edit {
    my ($self, $c) = @_;

    my $data = get_request_body($c);

    my @edits = grep { $_ } $self->create_edits($c, $data, 1);

    $c->model('Edit')->load_all(@edits);

    my @previews = map {
        my $edit = $_;

        my $edit_template = $edit->edit_template;
        my $vars = { edit => $edit, c => $c, allow_new => 1 };
        my $out = '';

        my $preview = $TT->process("edit/details/${edit_template}.tt", $vars, \$out)
            ? $out : '' . $TT->error();

        { preview => $preview, editName => $edit->edit_name };
    } @edits;

    $c->res->body($JSON->encode({ previews => \@previews }));
}

no Moose;
1;

=head1 COPYRIGHT

Copyright (C) 2014 MetaBrainz Foundation

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

=cut