package MusicBrainz::Server::Edit::Area;
use Moose::Role;
use namespace::autoclean;

use MusicBrainz::Server::Translation 'l';

sub edit_category { l('Area') }

sub editor_may_edit {
    my ($self) = @_;
    return $self->editor->is_location_editor;
}

1;
