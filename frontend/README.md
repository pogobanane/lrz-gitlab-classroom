# Generate a new link

For:

- lecture/course `"l"`,
- cohort `"c"`,
- (optional matrikel `"m"`,)
- arbitrary keys, e.g., "r", "g", "t"

a link can be generated using:

```bash
curl -s -d '{"r": 97579, "g": 46686, "t": 97841, "l": "950315978", "c": "17W"}' 'https://maestria.net.in.tum.de/link' | jq -r .url
```

# Configuration with environment variables

- `GITLAB_OAUTH_CLIENT_ID`, `GITLAB_OAUTH_CLIENT_SECRET`, `GITLAB_OAUTH_SCOPE`: GitLab OAuth2 credentials; description presented to student; used to retrieve student information
- `TUMONLINE_OAUTH_CLIENT_ID`, `TUMONLINE_OAUTH_CLIENT_SECRET`: TUMonline OAuth2 credentials for

- `STATE_DIRECTORY`: existing directory in which the application may store its SQLite3 database `mojo.sql`
- `SECRET` (optional): application secret; used for cookies/JWT; if set secrets remain valid across application restarts

# Development Server

```bash
./app.pl daemon -p -m development -l http://localhost:8080
```

# Tests

Export `CI=1` to use the mocked OAuth2 providers.
Run tests with `prove`.

# Documentation

Notes on TUMonline API are available as mail for LDAP-group `svm`.  TUMonline
OAuth2 access token was requested from mailto:it-support@tum.de (information
provided as described in the [wiki](https://wiki.tum.de/pages/viewpage.action?spaceKey=docs&title=TUMonline+OAuth+Zugang+beantragen)).

Students are considered part of a lecture if they are assigned a Fixplatz, only.

GitLab OAuth2 access token should be created as [group owned application](https://docs.gitlab.com/ee/integration/oauth_provider.html#group-owned-applications).

## Access Token

To grant students access, an additional access token is required.  Here it might
make sense to use a [project access token](https://docs.gitlab.com/ee/user/project/settings/project_access_tokens.html#group-access-token-workaround).
(Limit exploitability in case of breach.  User access tokens are too powerful.)
The required scope of the access token depends on the use case.

_Note_: In their infinite wisdom GitLab decided to set the maximum life time of
        tokens to 1 year.  If things fail, this might be a cause.

### Git Tagging Webhook (IITM)

Tagging requires ability to push to the repository.  Thus, this requires at
least *Maintainer* role.  Also, the *API scope* should suffice.

### Advanced GitLab Interaction (ACN, GRNVS)

ACN and GRNVS create repositories for the students.  This tasks requires *Owner*
role.  However, the *API scope* should suffice.
