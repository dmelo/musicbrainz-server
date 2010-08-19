package MusicBrainz::Server::Controller::WS::1::Role::LoadEntity;
use Moose::Role;

use aliased 'MusicBrainz::Server::WebService::XMLSerializerV1';

use MusicBrainz::Server::Data::Utils qw( type_to_model );
use MusicBrainz::Server::Validation;

has 'serializer' => (
    is => 'ro',
    default => sub { XMLSerializerV1->new }
);

sub bad_req
{
    my ($self, $c, $error) = @_;
    $c->res->status(400);
    $c->res->content_type("text/plain; charset=utf-8");
    $c->res->body($self->serializer->output_error($error));
    $c->detach;
}

sub model {
    my ($self, $c, $type) = @_;

    if($type eq 'artist' || $type eq 'release' || $type eq 'label' || $type eq 'track') {
        my $model  = $c->model( type_to_model($type) );
        return $model;
    }
    else {
        $self->bad_req($c, "$type is not a valid type");
    }
}

sub load
{
    my ($self, $c, $model, $id) = @_;

    if(MusicBrainz::Server::Validation::IsGUID($id) &&
          (my $entity = $model->get_by_gid($id))) {
        return $entity;
    }
    else {
        $self->bad_req($c, "Could not load $id");
    }
}

1;


