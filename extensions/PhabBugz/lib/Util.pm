# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::PhabBugz::Util;

use 5.10.1;
use strict;
use warnings;

use Bugzilla::Bug;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Logging;
use Bugzilla::User;
use Bugzilla::Types qw(:types);
use Bugzilla::Util qw(mojo_user_agent trim);
use Bugzilla::Extension::PhabBugz::Constants;
use Bugzilla::Extension::PhabBugz::Types qw(:types);

use List::MoreUtils qw(any);
use List::Util qw(first);
use Try::Tiny;
use Type::Params qw( compile );
use Type::Utils;
use Types::Standard qw( :types );
use Mojo::JSON qw(encode_json);

use base qw(Exporter);

our @EXPORT = qw(
  create_revision_attachment
  get_attachment_revisions
  get_bug_role_phids
  intersect
  is_attachment_phab_revision
  request
  set_attachment_approval_flags
  set_phab_user
);

# Set approval flags on Phabricator revision bug attachments.
sub set_attachment_approval_flags {
  my ($attachment, $revision, $user, $status) = @_;

  # The repo short name is the appropriate value that aligns with flag names.
  my $repo_name = $revision->repository->short_name;
  my $approval_flag_name = "approval-mozilla-$repo_name";
  INFO("Setting $approval_flag_name flag on revision attachment.");

  my @old_flags;
  my @new_flags;

  # Find the current approval flag state if it exists.
  foreach my $flag (@{$attachment->flags}) {
    # Ignore for all flags except the approval flag.
    next if $flag->name ne $approval_flag_name;

    # Set the flag to it's new status. If it already has that status,
    # it will be a non-change.
    INFO("Set existing `$approval_flag_name` flag to `$status`.");
    push @old_flags, {id => $flag->id, status => $status};
    last;
  }

  # If we didn't find an existing approval flag to update, add it now.
  if (!@old_flags) {
    my $approval_flag = Bugzilla::FlagType->new({name => $approval_flag_name});
    if ($approval_flag) {
      push @new_flags, {
        setter   => $user,
        status   => $status,
        type_id  => $approval_flag->id,
      };
    }
  }

  $attachment->set_flags(\@old_flags, \@new_flags);
}

sub create_revision_attachment {
  state $check = compile(Bug, Revision, Str, User);
  my ($bug, $revision, $timestamp, $submitter) = $check->(@_);

  my $phab_base_uri = Bugzilla->params->{phabricator_base_uri};
  ThrowUserError('invalid_phabricator_uri') unless $phab_base_uri;

  my $revision_uri = $phab_base_uri . "D" . $revision->id;

  # Check for previous attachment with same revision id.
  # If one matches then return it instead. This is fine as
  # BMO does not contain actual diff content.
  my @review_attachments
    = grep { is_attachment_phab_revision($_) } @{$bug->attachments};
  my $attachment
    = first { trim($_->data) eq $revision_uri } @review_attachments;


  if (!defined $attachment) {
    # No attachment is present, so we can now create new one

    if (!$timestamp) {
      ($timestamp) = Bugzilla->dbh->selectrow_array("SELECT NOW()");
    }

    # If submitter, then switch to that user when creating attachment
    local $submitter->{groups} = [Bugzilla::Group->get_all]; # We need to always be able to add attachment
    my $restore_prev_user = Bugzilla->set_user($submitter, scope_guard => 1);

    $attachment = Bugzilla::Attachment->create({
      bug         => $bug,
      creation_ts => $timestamp,
      data        => $revision_uri,
      description => $revision->title,
      filename    => 'phabricator-D' . $revision->id . '-url.txt',
      ispatch     => 0,
      isprivate   => 0,
      mimetype    => PHAB_CONTENT_TYPE,
    });

    # When the revision belongs to an uplift repo, set appropriate approval flags to `?`.
    if ($revision->repository && $revision->repository->is_uplift_repo()) {
      set_attachment_approval_flags($attachment, $revision, $submitter, '?');
      $attachment->update($timestamp);
    }

    # Insert a comment about the new attachment into the database.
    $bug->add_comment(
      $revision->summary,
      {
        type        => CMT_ATTACHMENT_CREATED,
        extra_data  => $attachment->id,
        is_markdown => (Bugzilla->params->{use_markdown} ? 1 : 0)
      }
    );
    delete $bug->{attachments};
  }

  # Assign the bug to the submitter if it isn't already owned and
  # the revision has reviewers assigned to it.
  # Skip this change if 'leave-open' and 'intermittent-failure'
  # keywords are set (bug 1673348).
  if (
    !is_bug_assigned($bug)
    && $revision->status ne 'abandoned'
    && @{$revision->reviews}
    && !($bug->has_keyword('leave-open') && $bug->has_keyword('intermittent-failure'))
  ) {
    INFO('Assigning bug ' . $bug->id . ' to ' . $submitter->email);
    $bug->set_assigned_to($submitter);
    if (any { $bug->status->name eq $_ } 'NEW', 'UNCONFIRMED') {
      INFO('Setting bug ' . $bug->id . ' to ASSIGNED');
      $bug->set_bug_status('ASSIGNED');
    }
  }

  return $attachment;
}

sub intersect {
  my ($list1, $list2) = @_;
  my %e = map { $_ => undef } @{$list1};
  return grep { exists($e{$_}) } @{$list2};
}

sub get_bug_role_phids {
  state $check = compile(Bug);
  my ($bug) = $check->(@_);

  my @bug_users = ($bug->reporter);
  push(@bug_users, $bug->assigned_to) if is_bug_assigned($bug);
  push(@bug_users, $bug->qa_contact)  if $bug->qa_contact;
  push(@bug_users, @{$bug->cc_users}) if @{$bug->cc_users};

  my $phab_users = Bugzilla::Extension::PhabBugz::User->match(
    {ids => [map { $_->id } @bug_users]});

  return [map { $_->phid } @{$phab_users}];
}

sub is_bug_assigned {
  return $_[0]->assigned_to->email ne 'nobody@mozilla.org';
}

sub is_attachment_phab_revision {
  state $check = compile(Attachment);
  my ($attachment) = $check->(@_);
  return $attachment->contenttype eq PHAB_CONTENT_TYPE;
}

sub get_attachment_revisions {
  state $check = compile(Bug);
  my ($bug) = $check->(@_);

  my @attachments
    = grep { is_attachment_phab_revision($_) } @{$bug->attachments()};

  return unless @attachments;

  my @revision_ids;
  foreach my $attachment (@attachments) {
    my ($revision_id) = ($attachment->filename =~ PHAB_ATTACHMENT_PATTERN);
    next if !$revision_id;
    push(@revision_ids, int($revision_id));
  }

  return unless @revision_ids;

  my @revisions;
  foreach my $revision_id (@revision_ids) {
    my $revision = Bugzilla::Extension::PhabBugz::Revision->new_from_query(
      {ids => [$revision_id]});
    push @revisions, $revision if $revision;
  }

  return \@revisions;
}

sub request {
  state $check = compile(Str, HashRef);
  my ($method, $data) = $check->(@_);
  my $request_cache = Bugzilla->request_cache;
  my $params        = Bugzilla->params;
  my $ua            = $request_cache->{phabricator_ua} ||= mojo_user_agent();

  my $phab_api_key = $params->{phabricator_api_key};
  ThrowUserError('invalid_phabricator_api_key') unless $phab_api_key;
  my $phab_base_uri = $params->{phabricator_base_uri};
  ThrowUserError('invalid_phabricator_uri') unless $phab_base_uri;

  my $full_uri = $phab_base_uri . '/api/' . $method;

  $data->{__conduit__} = {token => $phab_api_key};

  my $response
    = $ua->post($full_uri => form => {params => encode_json($data)})->result;
  ThrowCodeError('phabricator_api_error', {reason => $response->message})
    if $response->is_error;

  my $result = $response->json;
  ThrowCodeError('phabricator_api_error', {reason => 'JSON decode failure'})
    if !defined($result);
  ThrowCodeError('phabricator_api_error',
    {code => $result->{error_code}, reason => $result->{error_info}})
    if $result->{error_code};

  return $result;
}

sub set_phab_user {
  my $user = Bugzilla::User->new({name => PHAB_AUTOMATION_USER});
  $user->{groups} = [Bugzilla::Group->get_all];

  return Bugzilla->set_user($user, scope_guard => 1);
}

1;
