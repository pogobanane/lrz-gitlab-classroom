# Minimal Classroom for LRZ's GitLab

## Maintain

If things don't work:

- Check if github token is expired after a year.


## Lecturer Usage

{"c":"17W","g":46686,"l":"950798529","r":97579,"t":97841}

where l is the lecture id


## Design

The system consists of two parts. A perl-based website, and a python-based worker/backend. Students receive a (possibly) unique sign-up link to sign up. After signup, the website stores the user info in the state dir mojo.db. The python worker monitors files in the state dir for changes, pops the new users out of mojo.db, and creates the student repositories on gitlab accordingly.

### GitLab API Worker Actions

For each student signup request, the worker performs these GitLab operations:

1. Authenticate to GitLab using the student's OAuth token
2. Get or create a student record in the local database with a pseudo-random UID
3. Sync the student's SSH public keys from GitLab to the database
4. Create a subgroup for the student under the course's parent group (e.g., `Student u0123`)
5. For each assignment within its active date range:
   1. Create a private project/repository in the student's group with minimal features (no wiki, issues, MRs, packages, pages, etc.)
   2. If the assignment has a `ci` field, enable shared runners and set `ci_config_path`
   3. Add the student as Developer to the project (expires at `notAfter`)
   4. Protect tags `final/*` and `submission/*` (Maintainer-only)
   5. Add push rule restricting branch names to `main`
   6. Protect the `main` branch
6. Add the student as Reporter to the course material repository (expires at `expiry_date`)
7. Backup the student database to JSON
8. Optionally run an update hook script for rsync etc.


## Safety

Ensure that the following is given for compliance with campus.tum.de OAuth.

- Bestätigung dass die Anwendung ausschließlich über https:// mit HSTS erreichbar ist
- Bestätigung dass die Anwendung angemessenen Schutz vor Cross-Site Request-Forgery mitbringt, insbesondere Verknüpfung und Validierung des OAuth "state" Parameters mit der Nutzer-Session. Fehlende Validierung des "state" Parameters erlaubt das Unterschieben fremder Nutzer-Sessions!
- Bestätigung dass die Anwendung keine Einbettung in Frames gestattet (X-Frame-Options oder Content-Security-Policy Header)


## TODO

- Document example environment file
