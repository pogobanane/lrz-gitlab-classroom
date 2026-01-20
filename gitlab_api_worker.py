#!/usr/bin/env python3

import random
import subprocess
import time
from datetime import date
import asyncio
import json
import logging
import os
import pathlib
import types
import click

import aionotify  # type: ignore
import peewee  # type: ignore
import playhouse.db_url  # type: ignore
import playhouse.reflection  # type: ignore

import gitlab
from gitlab import GitlabUpdateError
from gitlab.v4.objects import ProjectManager, Project, ProjectMemberManager, Group, GroupMemberManager
from playhouse.shortcuts import model_to_dict

GITLAB_URL: str = "https://gitlab.lrz.de/"
GITLAB_TOKEN_MATERIAL: str = os.environ.get('GITLAB_TOKEN_MATERIAL')
GITLAB_ADMIN_MATERIAL = gitlab.Gitlab(GITLAB_URL, private_token=GITLAB_TOKEN_MATERIAL)
GITLAB_TOKEN_STUDENTS: str = os.environ.get('GITLAB_TOKEN')
GITLAB_ADMIN_STUDENTS = gitlab.Gitlab(GITLAB_URL, private_token=GITLAB_TOKEN_STUDENTS)

SVM_ID_MIN: int = int(os.environ.get("SVM_ID_MIN", 100))
SVM_ID_MAX: int = int(os.environ.get("SVM_ID_MAX", 1999))
SVM_ID_STEP: int = int(os.environ.get("SVM_ID_STEP", 1))

database = peewee.SqliteDatabase(None)

static_project_config = {
    'auto_devops_enabled': False,
    'container_registry_access_level': 'disabled',
    'initialize_with_readme': False,
    'issues_access_level': 'disabled',
    'lfs_enabled': False,
    'merge_requests_access_level': 'disabled',
    'forking_access_level': 'disabled',
    'operations_access_level': 'disabled',
    'packages_enabled': False,
    'pages_access_level': 'disabled',
    'requirements_access_level': 'disabled',
    'security_and_compliance_access_level': 'disabled',
    'public_builds': False,
    'repository_access_level': 'enabled',
    'snippets_access_level': 'disabled',
    'wiki_access_level': 'disabled',
    'visibility': 'private',
    'analytics_access_level': 'disabled',
    'shared_runners_enabled': False,
    'jobs_enabled': False,
    'builds_access_level': 'disabled',
    'wiki_enabled': False,
    'merge_requests_enabled': False,
    'issues_enabled': False,
    'requirements_enabled': False,
    'security_and_compliance_enabled': False,
    'model_experiments_access_level': 'disabled',
    'model_registry_access_level': 'disabled',
    'monitor_access_level': 'disabled',
    'environments_access_level': 'disabled',
    'feature_flags_access_level': 'disabled',
    'infrastructure_access_level': 'disabled',
    'releases_access_level' : 'disabled'
}

enable_ci_config = {
    'shared_runners_enabled': True,
    'jobs_enabled': True,
    'builds_access_level': 'enabled',
}


class Student(peewee.Model):
    id = peewee.PrimaryKeyField()
    course = peewee.TextField()
    matrikel = peewee.TextField()
    uid = peewee.TextField(unique=True)
    gitlab_id = peewee.IntegerField(unique=True)

    class Meta:
        database = database
        indexes = (
            (('course', 'matrikel'), True),
        )


class PublicKey(peewee.Model):
    owner = peewee.ForeignKeyField(Student, backref='keys')
    key = peewee.TextField()

    class Meta:
        database = database


def connect_store(store):
    database.init(store, pragmas={'foreign_keys': 1})
    with database:
        database.create_tables([Student, PublicKey])


async def on_update(model: peewee.Model, store: str, courses_file: str, update_hook: str) -> None:
    """ process database update """


    # load courses from json
    courses_text = pathlib.Path(courses_file).read_text()
    courses = json.loads(courses_text)

    newest: model.requests = None
    try:
        connect_store(store)

        for newest in model.requests.select().order_by(model.requests.id.desc()):
            if newest is None:
                logging.debug("Nothing to process for now")
                return

            metadata = json.loads(newest.jwt, object_hook=lambda d: types.SimpleNamespace(**d))
            logging.debug(
                "Process entry:\n\t%s\n\t%s\n\t%s",
                newest.matrikel,
                newest.gitlab_access_token,
                metadata,
            )

            if metadata.l not in courses.keys():
                logging.debug(f"Unknown course: {metadata.l}")
                newest.delete_instance()
                continue

            try:
                process_gitlab_task(newest.matrikel, newest.gitlab_access_token, metadata, courses)
                newest.delete_instance()
            except gitlab.exceptions.GitlabAuthenticationError:
                logging.debug("Invalid access token, deleting tasks")
                newest.delete_instance()

        # Backup storage
        filename = f'{store}.json' #{date.today().strftime("%Y-%m-%d")}

        with open(filename, 'w') as f:
            students = list(map(lambda x: model_to_dict(x, backrefs=True), Student.select()))
            f.write(json.dumps(students))

        # Call script for rsync etc
        if update_hook is not None:
            subprocess.run(f'{update_hook} {os.path.abspath(filename)}', shell=True, check=False)
    except Exception as err:  # pylint: disable=broad-except
        # request table empty; model does not exist; hence, broad exception
        logging.exception("Unknown exception occurred", exc_info=err)
        if newest is not None:
            newest.delete_instance()


def process_gitlab_task(matrikel: str, oauth_token: str, metadata, courses: dict):
    student = gitlab.Gitlab(GITLAB_URL, oauth_token=oauth_token)
    student.auth()

    user_gitlab_id = student.user.id
    user_gitlab_name = student.user.username

    course = courses.get(metadata.l)

    student_data = Student.get_or_none(
        (Student.matrikel == matrikel) & (Student.course == metadata.l)
    )
    if student_data is None:
        logging.debug(f'New student: {matrikel}')
        student_id = get_next_student_id()
        student_data = Student.create(matrikel=matrikel, gitlab_id=user_gitlab_id, uid=student_id, course=metadata.l)
        logging.debug('Creating new user %s' % student_id)
    else:
        logging.debug(f'User already exists: ({student_data.matrikel}, {student_data.gitlab_id}, {student_data.uid})')
        student_id = student_data.uid
        if user_gitlab_id != student_data.gitlab_id:
            student_data.gitlab_id = user_gitlab_id
            student_data.save()
            logging.error('Gitlab ID Changed for %s - %s: Old %s New %s' % (
                matrikel, user_gitlab_name, student_data.gitlab_id, user_gitlab_id))

    user_gitlab_keys = set()
    for key in student.user.keys.list():
        user_gitlab_keys.add(key.key)
    for db_key in student_data.keys:
        if db_key.key not in user_gitlab_keys:
            db_key.delete_instance()
        else:
            user_gitlab_keys.remove(db_key.key)
    for new_key in user_gitlab_keys:
        PublicKey(owner=student_data, key=new_key).save()


    student_gitlab_group: Group = GITLAB_ADMIN_STUDENTS.groups.get(course.get("group"), lazy=True)

    invite_to_container = False
    assignments = course.get('assignments')
    if assignments is not None:
        student_group: Group = None
        group_name = f'{student_id}'

        # Check if student group exists
        for group in student_gitlab_group.subgroups.list(all=True, iterator=True, simple=True):
            if group.path == group_name:
                student_group = GITLAB_ADMIN_STUDENTS.groups.get(group.id)
                break

        tutor = False
        if course.get('tutors') is not None:
            tutor = group_name in course.get('tutors')
            if tutor:
                logging.info(f'Found Tutor {group_name}')

        if student_group is None:
            student_group = GITLAB_ADMIN_STUDENTS.groups.create({
                'name': f'Student {group_name}',
                'path': group_name,
                'parent_id': student_gitlab_group.id,
            })
            time.sleep(5)

        for assignment in assignments:
            invite_to_container = add_create_project(course, assignment, student_group, GITLAB_ADMIN_STUDENTS, student.user, tutor) or invite_to_container
        if invite_to_container:
            # Invite user to his group if a new repo was created
            add_user(student.user, student_group, gitlab.const.REPORTER_ACCESS, course.get('expiry_date'))

    # Add User to Repositories
    material: Project = GITLAB_ADMIN_MATERIAL.projects.get(course.get('material'))
    add_user(student.user, material, gitlab.const.REPORTER_ACCESS, course.get('expiry_date'))


def svm_format_id(uid: int):
    """Validate and format VM ID"""
    if uid < SVM_ID_MIN or uid > SVM_ID_MAX:
        raise ValueError(f"Invalid SVM UID for lecture: {uid}")
    return f"u{uid:04d}"

def get_next_student_id() -> str:
    """Get a pseudo-random unused UID that satisfies the min/max/step rules"""
    # smallest and largest ID that are in the interval with >=step headroom
    svm_id_min = SVM_ID_STEP * (1 + ((SVM_ID_MIN - 1) // SVM_ID_STEP))
    svm_id_max = SVM_ID_MAX - SVM_ID_MAX % SVM_ID_STEP
    all_uids = set(
        map(
            svm_format_id,
            range(svm_id_min, svm_id_max, SVM_ID_STEP),
        )
    )
    existing = set(s.uid for s in Student.select())
    free_uids = list(all_uids - existing)
    return random.choice(free_uids)

def add_user(user, project_group, role, expiry_date):
    project_members: ProjectMemberManager | GroupMemberManager = project_group.members
    is_member = False
    for member in project_members.list(iterator=True):
        if member.id == user.id:
            is_member = True
            break
    if not is_member:
        logging.debug('Invite user %s to project %s' % (user.id, project_group.id))
        try:
            project_members.create({
                'user_id': user.id,
                'access_level': role,
                'expires_at': expiry_date,
            })
        except gitlab.exceptions.GitlabCreateError as err:
            logging.info('Could not invite user %s' % user.id, exc_info=err)
    else:
        try:
            logging.debug('User %s is already member of project %s' % (user.id, project_group.id))
            member = project_group.members.get(user.id)
            member.access_level = role
            member.expires_at = expiry_date
            member.save()
        except gitlab.exceptions.GitlabCreateError as err:
            logging.info('Could not update user %s' % user.id, exc_info=err)


def add_create_project(course, assignment, group: Group, group_admin, user, tutor: bool):
    if not tutor:
        not_before = assignment.get('notBefore')
        if not_before is not None:
            if date.today() < date.fromisoformat(not_before):
                logging.info(f'{assignment.get("name")} not yet available')
                return False
        not_after = assignment.get('notAfter')
        if date.fromisoformat(not_after) < date.today():
            # Old assignment
            logging.info(f'{assignment.get("name")} already finished')
            return False

    if assignment.get('ci'):
        project_config = static_project_config | enable_ci_config |  {'ci_config_path': assignment.get('ci')}
    else:
        project_config = static_project_config

    if course.get('template') and course.get('template_group'):
        project_config |= {
            'use_custom_template': True,
            'group_with_project_templates_id': course.get('template_group'),
            'template_project_id': course.get('template'),
        }

    project: Project = None
    for p_iter in group.projects.list(all=True, iterator=True, simple=True):
        if p_iter.path == assignment.get('path'):
            project = group_admin.projects.get(p_iter.id)
            break
    if project is None:
        project = group_admin.projects.create({
            'name': assignment.get('name'),
            'path': assignment.get('path'),
            'namespace_id': group.id,
        } | project_config)
        time.sleep(5)
    
    add_user(user, project, gitlab.const.DEVELOPER_ACCESS, assignment.get('notAfter'))

    # Protect tags
    protect_tag(project, 'final/*', gitlab.const.MAINTAINER_ACCESS)
    protect_tag(project, 'submission/*', gitlab.const.MAINTAINER_ACCESS)

    # Add pushrule
    add_push_rule(project, branch_name_regex='^main$')

    # Add protected branch
    protect_branch(project, branch_name="main", push_access_level=gitlab.const.DEVELOPER_ACCESS)

    return True

def protect_branch(project, branch_name="", push_access_level=gitlab.const.MAINTAINER_ACCESS):
    """Protect branches for students. For example for the grades branch"""
    try:
        project.protectedbranches.create(
            {
                "name": branch_name,
                "merge_access_level": gitlab.const.MAINTAINER_ACCESS,
                "push_access_level": push_access_level,
                "code_owner_approval_required": False,
            }
        )
    except gitlab.exceptions.GitlabCreateError as error:
        logging.info(f'Could not protect branch for {project.name}')

def protect_tag(project, tag_name, access_level):
    try:
        project.protectedtags.create({
            'name': tag_name,
            'create_access_level': access_level
        })
    except gitlab.exceptions.GitlabCreateError as err:
        logging.info(f'Could not protect tag {tag_name} for {project.name}')


def add_push_rule(project, branch_name_regex=""):
    try:
        project.pushrules.create({'branch_name_regex': branch_name_regex})
    except gitlab.exceptions.GitlabCreateError as err:
        logging.info(f'Could add push rule for {project.name}')


async def watch_loop(watcher: aionotify.Watcher, model: types.SimpleNamespace, store: str, courses: str, update_hook) -> None:
    """ call appropriate function for each received event """
    await watcher.setup(asyncio.get_running_loop())
    await on_update(model, store, courses, update_hook)
    while not watcher.closed:
        logging.debug("Waiting for event")
        event: aionotify.Event = await watcher.get_event()  # pylint: disable=no-member
        logging.debug("Got event: %s", event)
        task: asyncio.Task = asyncio.create_task(on_update(model, store, courses, update_hook))
        logging.debug("Scheduled task: %s", task)
    watcher.close()


@click.command()
@click.option('--db', type=click.Path(exists=False, file_okay=True, dir_okay=False), required=True)
@click.option('--store', type=click.Path(exists=False, file_okay=True, dir_okay=False), required=True)
@click.option('--courses', type=click.Path(exists=False, file_okay=True, dir_okay=False), required=True)
@click.option('--error-log', type=click.Path(exists=False, file_okay=True, dir_okay=False), required=True)
@click.option('--update-hook', type=click.Path(exists=False, file_okay=True, dir_okay=False), required=False)
def main(db: str, store: str, courses: str, error_log: str, update_hook: str):
    """ wait for changes and call appropriate function """
    db = pathlib.Path(db)
    logging.basicConfig(level=logging.DEBUG)
    file_handler = logging.FileHandler(error_log)
    file_handler.setLevel(logging.ERROR)
    file_handler.setFormatter(logging.Formatter(fmt='%(asctime)s :: %(name)s :: %(levelname)-8s :: %(message)s'))
    logging.getLogger().addHandler(file_handler)

    logging.debug(f'Loading requests from: {db}')
    logging.debug(f'Opening sqlite store: {store}')

    # setup database connection(s)
    database: peewee.Database = playhouse.db_url.connect("sqlite+pool:///%s" % db)
    model = types.SimpleNamespace(**playhouse.reflection.generate_models(database))

    # prepare inotify watcher
    watcher = aionotify.Watcher()
    watcher.watch(
        alias=db.name, path=str(db.parent), flags=aionotify.Flags.MODIFY
    )

    # process events
    asyncio.run(watch_loop(watcher, model, store, courses, update_hook))


if __name__ == "__main__":
    main()
