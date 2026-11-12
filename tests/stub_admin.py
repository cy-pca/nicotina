"""The stub TX.WTF instance's admin endpoints (tests/stub_txwtf.py), for nicotina's Admin view.

Python stdlib only, like the stub. The shapes follow txwtf's routes and models (txwtf/api,
txwtf/api/model.py): UserListResponse, UserProfileResponse, Group, GroupAssociation, the member
dicts of get_groups_members, InviteCodeResponse, InviteOnlyModeResponse and SystemLogResponse.

  GET  /user/list?limit=&offset=&username=&order_by=&order_desc=
                               the accounts, a page at a time (UserListRead)
  PUT  /user/update            {user_id, enabled | login_2fa_email_enabled} -> the profile
  PUT  /group/user/sysadmin    {user_id, is_admin} -> the profile
  GET  /group/all, GET /group/?group_id=, GET /group/members?group_id=
  POST /group/                 {group_name, description} -> the Group
  DELETE /group/?group_name=   null
  POST /group/user, DELETE /group/user (a JSON body), PUT /group/user/admin
                               {group_id, user_id, is_group_admin}
  GET  /perms/codes            every permission's name and code (public, as txwtf's)
  GET  /group/perms?group_id=  the codes a group grants its members
  POST /perms/                 {group_id, permission_codes} -> the GroupPermissions made
  DELETE /perms/?group_id=     a JSON list of codes in the body -> null
  GET  /invite/mode, PUT /invite/mode {invite_only}
  GET  /invite/codes?include_inactive=&limit=&offset=   the signed-in admin's own codes
  POST /invite/codes {max_uses, note}; DELETE /invite/codes/{id}; POST /invite/codes/{id}/reactivate
  GET  /site/title, /site/description, /site/timezone, /site/default_user_group,
       /site/admin_group, /site/password/...   (public, as txwtf's)
  PUT  /site/title {title}, /site/description {description}, /site/timezone {timezone}
  GET  /logs/?limit=&offset=&order_desc=&event_code=    the system log, newest first

Only an administrator (ada, is_admin) may use them; anyone else gets what txwtf answers for a
missing permission: 401 {"detail": "Access Denied!! (AccessDenied)"} (map_txwtf_errors maps
AccessDenied to 401, so a client must not take every 401 for an expired session). What an admin
changes holds for the stub's run: a disabled account can't sign in (400 "Disabled user N
(DisabledUser)", as authorized_session_launch refuses it) and its tokens stop working, and each
change is a new entry at the top of the system log, as txwtf logs them.
"""

import json
import threading

ACCESS_DENIED = "Access Denied!! (AccessDenied)"

# txwtf's event codes, as the web app names them (EVENT_CODE_NAMES in static/js/app.js).
USER_LOGIN, USER_CREATE, USER_UPDATE, USER_LOGOUT, SETTING_CHANGE = 1, 2, 3, 4, 5
GROUP_CREATE, GROUP_DELETE, GROUP_ADD_USER, GROUP_REMOVE_USER = 8, 9, 10, 11
GROUP_ADD_PERMISSION, GROUP_REMOVE_PERMISSION = 12, 13

# Some of txwtf's permission codes, with their numbers (PermissionCode numbers PermissionCodeInfo's
# names from 1, in order). GET /perms/codes answers these.
PERMISSIONS = {
    "UserRead": 13, "UserReadSelf": 15, "UserWrite": 23, "GroupsRead": 26, "GroupCreate": 29,
    "GroupRemove": 30, "GroupAddUser": 32, "GroupRemoveUser": 34, "GroupAddPermission": 36,
    "GroupRemovePermission": 37, "SiteTitleSet": 89, "SystemLogRead": 130,
    "SystemLogReadSelf": 131, "UserListRead": 132, "StatsUserView": 173,
    "SocialPostCreateAsUser": 255, "SocialPostReadAsUser": 257, "SocialHashtagRead": 296,
    "InviteCodeAdmin": 300,
}

# The system log, newest first: (time, username or None, event code, description, endpoint).
LOG = [
    ("2026-10-30T23:10:04", "alan@peer.example", USER_LOGIN, "Brokered sign-in from peer.example",
     "/user/login/oidc"),
    ("2026-10-30T22:50:12", "grace", USER_LOGIN, "Signed in with the emailed code", "/user/login/2fa"),
    ("2026-10-30T22:41:57", "ada", SETTING_CHANGE, "site description changed", "/site/description"),
    ("2026-10-30T21:05:30", "linus", USER_LOGIN, "Password change required", "/user/login"),
    ("2026-10-30T20:12:44", "mary", USER_UPDATE, "description updated", "/user/update"),
    ("2026-10-30T18:00:00", "ada", GROUP_ADD_USER, "mary added to users", "/group/user"),
    ("2026-10-30T12:00:00", None, 16, "Stats job completed in 2.1 s", None),
    ("2026-10-30T11:59:00", "ada", USER_LOGIN, "Signed in", "/user/login"),
    ("2026-10-29T09:00:00", "ada", GROUP_CREATE, "analysts created", "/group/"),
    ("2026-10-28T08:30:00", "slowpoke", USER_CREATE, "Registered with invite ENGINE-7Q2X",
     "/user/register"),
    ("2026-10-27T07:15:00", "bob@peer.example", USER_CREATE, "Brokered account from peer.example",
     "/user/login/oidc"),
    ("2026-10-26T06:00:00", "grace", USER_LOGOUT, "Signed out", "/user/logout"),
    ("2026-10-25T05:45:00", "ada", SETTING_CHANGE, "site title changed", "/site/title"),
    ("2026-10-24T04:30:00", None, 22, "Retention sweep completed", None),
]

# The groups: the default user group, one more, and the admin group (txwtf's "root").
GROUPS = [
    {"id": 1, "name": "users", "desc": "The default user group", "creator_user_id": 1},
    {"id": 2, "name": "analysts", "desc": "Reads the engine's tables", "creator_user_id": 1},
    {"id": 3, "name": "root", "desc": "The administrators", "creator_user_id": 1},
]
# Each group's members and whether each is its admin. The accounts' own lists (USERS[...]
# ["groups"] in the stub) say the same for users and analysts; root holds ada alone.
MEMBERS = {1: {"ada": False, "grace": False, "mary": False, "bob@peer.example": False, "eve": False,
           "ivy": False},
           2: {"ada": True}, 3: {"ada": True}}
# What each group grants its members (GET /group/perms): the default group a user's, analysts the
# statistics and their own log, root the administration (twelve, two pages of ten).
GRANTS = {
    1: ["UserReadSelf", "SocialPostCreateAsUser", "SocialPostReadAsUser", "SocialHashtagRead"],
    2: ["StatsUserView", "SystemLogReadSelf"],
    3: ["UserRead", "UserWrite", "GroupsRead", "GroupCreate", "GroupRemove", "GroupAddUser",
        "GroupRemoveUser", "GroupAddPermission", "GroupRemovePermission", "SiteTitleSet",
        "SystemLogRead", "UserListRead"],
}

# Ada's own invite codes, newest first (InviteCodeResponse).
INVITES = [
    {"id": 2, "code": "LOOM-4K9D", "creator_user_id": 1, "max_uses": 1, "use_count": 1,
     "is_active": False, "created_at": "2026-10-20T10:00:00", "expires_at": None,
     "note": "for Charles"},
    {"id": 1, "code": "ENGINE-7Q2X", "creator_user_id": 1, "max_uses": 10, "use_count": 3,
     "is_active": True, "created_at": "2026-10-01T09:00:00", "expires_at": "2026-12-31T00:00:00",
     "note": "the lecture"},
]

# What /site/... answers, before an admin changes it.
SITE = {
    "title": "TX.WTF",
    "description": "Austin's crypto club, on the web.",
    "timezone": "UTC",
    "default_user_group": "users",
    "admin_group": "root",
    "password/special_symbols": "!@#$%^&*",
    "password/min_length": 8,
    "password/max_length": 128,
    "password/special_symbols_enabled": 0,
    "password/min_length_enabled": 1,
    "password/max_length_enabled": 0,
    "password/digit_enabled": 1,
    "password/upper_enabled": 0,
    "password/lower_enabled": 0,
}


def _q(query, key, default=None):
    return query.get(key, [default])[0]


def _flag(query, key, default=False):
    v = _q(query, key)
    return default if v is None else v.lower() in ("1", "true", "yes")


class Admin:
    """The admin side of the stub's state. accounts: username -> the stub's USERS or AUTHORS
    entry (each has id, name and created_time or not); posts_of(username) counts their posts."""

    def __init__(self, accounts, avatar_of, posts_of):
        self.lock = threading.RLock()  # patch_profile runs inside _admin's hold too
        self.accounts = accounts
        self.avatar_of = avatar_of
        self.posts_of = posts_of
        self.enabled = {n: True for n in accounts}
        self.admins = {n for n, a in accounts.items() if a.get("is_admin")}
        self.two_factor = {n for n, a in accounts.items() if a.get("login_2fa_email_enabled")}
        self.groups = [dict(g) for g in GROUPS]
        self.members = {g: dict(m) for g, m in MEMBERS.items()}
        self.next_group = 4
        self.grants = {g: [PERMISSIONS[n] for n in names] for g, names in GRANTS.items()}
        self.invites = [dict(c) for c in INVITES]
        self.next_invite = 3
        self.invite_only = False
        self.site = dict(SITE)
        self.log = [{"id": 300 - i, "event_time": t, "username": u, "event_code": c,
                     "event_desc": d, "endpoint": e} for i, (t, u, c, d, e) in enumerate(LOG)]
        self.next_log = 301

    # --- what the rest of the stub asks ----------------------------------------------------

    def disabled(self, username):
        return not self.enabled.get(username, True)

    def is_admin(self, username):
        return username in self.admins

    def uses_code(self, username):
        """Whether the account signs in with the emailed second factor (an admin may turn it off)."""
        return username in self.two_factor

    def patch_profile(self, username, body):
        """A profile (UserProfileResponse) as an admin has left the account."""
        if username not in self.accounts:
            return body
        with self.lock:
            body["enabled"] = self.enabled[username]
            body["is_admin"] = username in self.admins
            body["login_2fa_email_enabled"] = username in self.two_factor
            body["groups"] = [{"group_id": g["id"], "group_name": g["name"],
                               "is_group_admin": self.members.get(g["id"], {}).get(username, False)}
                              for g in self.groups if username in self.members.get(g["id"], {})]
        return body

    def site_value(self, key):
        return self.site.get(key)

    # --- helpers ---------------------------------------------------------------------------

    def _id(self, username):
        return self.accounts[username]["id"]

    def _name_of(self, user_id):
        return next((n for n, a in self.accounts.items() if a["id"] == user_id), None)

    def _entry(self, user, code, desc, endpoint):
        # with self.lock held
        self.log.insert(0, {"id": self.next_log, "event_time": "2026-10-31T09:00:00",
                            "username": user, "event_code": code, "event_desc": desc,
                            "endpoint": endpoint})
        self.next_log += 1

    def _group(self, group_id):
        return next((g for g in self.groups if g["id"] == group_id), None)

    def _list_entry(self, n):
        a = self.accounts[n]
        return {
            "id": a["id"], "username": n,
            "email": a.get("email", n.split("@")[0] + "@example.org"),
            "name": a["name"], "avatar_url": self.avatar_of(n), "avatar_file_id": None,
            "card_image_url": a.get("card_image_url"), "email_verified": True,
            "enabled": self.enabled[n], "created_time": a.get("created_time", "2025-01-01T00:00:00"),
            "last_login": "2026-10-30T11:59:00", "last_activity": "2026-10-30T12:00:00",
            "status": a.get("status", "offline"), "is_admin": n in self.admins,
            "last_login_country": a.get("country", "US"), "post_count": self.posts_of(n),
            "view_count": a.get("view_count", 3), "engagement_score": "0", "is_monetized": False,
        }

    # --- the routes ------------------------------------------------------------------------

    def handle(self, h, method, path, query, user):
        """Answer an admin route for signed-in user USER: (status,) when it is one, else None.
        h is the stub's request handler (its reply and json_body)."""
        route = (method, path.rstrip("/") or "/")
        known = {
            ("GET", "/user/list"), ("PUT", "/user/update"), ("PUT", "/group/user/sysadmin"),
            ("GET", "/group/all"), ("GET", "/group"), ("POST", "/group"), ("DELETE", "/group"),
            ("GET", "/group/members"), ("POST", "/group/user"), ("DELETE", "/group/user"),
            ("PUT", "/group/user/admin"), ("GET", "/invite/mode"), ("PUT", "/invite/mode"),
            ("GET", "/invite/codes"), ("POST", "/invite/codes"), ("GET", "/logs"),
            ("PUT", "/site/title"), ("PUT", "/site/description"), ("PUT", "/site/timezone"),
            ("GET", "/group/perms"), ("POST", "/perms"), ("DELETE", "/perms"),
        }
        invite_one = path.startswith("/invite/codes/") and path.split("/")[3].isdigit()
        if route == ("GET", "/perms/codes"):  # public, as txwtf's
            return (h.reply(200, dict(PERMISSIONS)),)
        if route not in known and not invite_one:
            return None
        if user not in self.admins:
            return (h.reply(401, {"detail": ACCESS_DENIED}),)
        with self.lock:
            return (self._admin(h, method, route[1], path, query, user),)

    def _admin(self, h, method, route, path, query, user):
        invite_one = path.startswith("/invite/codes/") and path.split("/")[3].isdigit()
        if route == "/user/list":
            names = list(self.accounts)
            want = (_q(query, "username") or "").lower()
            if want:
                names = [n for n in names if want in n.lower()]
            order = _q(query, "order_by", "id")
            key = {"created_time": lambda n: (self.accounts[n].get("created_time", "2025-01-01T00:00:00"),
                                              self._id(n)),
                   "username": lambda n: n}.get(order, self._id)
            names.sort(key=key, reverse=_flag(query, "order_desc"))
            limit = min(int(_q(query, "limit", "50")), 100)
            offset = int(_q(query, "offset", "0"))
            return h.reply(200, {"users": [self._list_entry(n) for n in names[offset:offset + limit]],
                                 "total_count": len(names), "limit": limit, "offset": offset})
        if route in ("/user/update", "/group/user/sysadmin"):
            body = h.json_body() or {}
            n = self._name_of(body.get("user_id"))
            if n is None:
                return h.reply(404, {"detail": "User not found"})
            # As txwtf's models take them: is_admin is a required bool (null is a 422); enabled
            # and login_2fa_email_enabled are Optional, so null leaves them as they are.
            if route == "/group/user/sysadmin":
                if not isinstance(body.get("is_admin"), bool):
                    return h.reply(422, {"detail": "is_admin: a boolean"})
                (self.admins.add if body["is_admin"] else self.admins.discard)(n)
                self._entry(user, USER_UPDATE, f"{n} is_admin={body['is_admin']}", path)
            else:
                if isinstance(body.get("enabled"), bool):
                    self.enabled[n] = body["enabled"]
                    self._entry(user, USER_UPDATE, f"{n} enabled={self.enabled[n]}", path)
                if body.get("login_2fa_email_enabled") is False:
                    self.two_factor.discard(n)
                    self._entry(user, USER_UPDATE, f"{n} login_2fa_email_enabled=false", path)
            return h.reply(200, h.profile_of(n))
        if route == "/group/all":
            return h.reply(200, [dict(g, metadata_id=None) for g in self.groups])
        if route == "/group" and method == "GET":
            g = self._group(int(_q(query, "group_id", "0")))
            return h.reply(200, dict(g, metadata_id=None)) if g else \
                h.reply(400, {"detail": "Group not found (GroupDoesNotExist)"})
        if route == "/group" and method == "POST":
            body = h.json_body() or {}
            name = (body.get("group_name") or "").strip()
            if not name:
                return h.reply(422, {"detail": "group_name: required"})
            if any(g["name"] == name for g in self.groups):
                return h.reply(400, {"detail": f"Group {name} already exists (GroupExists)"})
            g = {"id": self.next_group, "name": name, "desc": body.get("description"),
                 "creator_user_id": self._id(user)}
            self.next_group += 1
            self.groups.append(g)
            self.members[g["id"]] = {}
            self._entry(user, GROUP_CREATE, f"{name} created", path)
            return h.reply(200, dict(g, metadata_id=None))
        if route == "/group" and method == "DELETE":
            name = _q(query, "group_name", "")
            g = next((g for g in self.groups if g["name"] == name), None)
            if g is None:
                return h.reply(400, {"detail": f"Group {name} does not exist (GroupDoesNotExist)"})
            self.groups.remove(g)
            self.members.pop(g["id"], None)
            self._entry(user, GROUP_DELETE, f"{name} deleted", path)
            return h.reply(200, None)
        if route == "/group/members":
            g = self._group(int(_q(query, "group_id", "0")))
            if g is None:
                return h.reply(400, {"detail": "Group not found (GroupDoesNotExist)"})
            members = sorted(self.members[g["id"]].items(), key=lambda kv: self._id(kv[0]))
            return h.reply(200, [{"user_id": self._id(n), "username": n,
                                  "name": self.accounts[n]["name"],
                                  "email": self.accounts[n].get("email", ""),
                                  "avatar_url": self.avatar_of(n), "is_group_admin": a}
                                 for n, a in members])
        if route == "/group/perms":
            g = self._group(int(_q(query, "group_id", "0")))
            if g is None:
                return h.reply(400, {"detail": "Group not found (GroupDoesNotExist)"})
            return h.reply(200, list(self.grants.get(g["id"], [])))
        if route == "/perms" and method == "POST":
            body = h.json_body() or {}
            g = self._group(body.get("group_id"))
            codes = body.get("permission_codes")
            if g is None or not isinstance(codes, list) or \
                    not all(c in PERMISSIONS.values() for c in codes):
                return h.reply(422, {"detail": "group_id and permission_codes: valid ones"})
            have = self.grants.setdefault(g["id"], [])
            made = []
            for c in codes:
                if c in have:
                    return h.reply(400, {"detail": f"Group {g['name']} has it (GroupHasPermission)"})
                have.append(c)
                made.append({"id": 5000 + c, "metadata_id": None, "group_id": g["id"],
                             "permission": c})
                self._entry(user, GROUP_ADD_PERMISSION, f"{g['name']} granted {c}", "/perms/")
            return h.reply(200, made)
        if route == "/perms" and method == "DELETE":
            g = self._group(int(_q(query, "group_id", "0")))
            n = int(h.headers.get("Content-Length") or 0)
            try:
                codes = json.loads(h.rfile.read(n) or b"null")
            except ValueError:
                codes = None
            if g is None or not isinstance(codes, list):
                return h.reply(422, {"detail": "group_id and a list of codes"})
            have = self.grants.setdefault(g["id"], [])
            for c in codes:
                if c in have:
                    have.remove(c)
                    self._entry(user, GROUP_REMOVE_PERMISSION, f"{g['name']} lost {c}", "/perms/")
            return h.reply(200, None)
        if route in ("/group/user", "/group/user/admin"):
            body = h.json_body() or {}
            g = self._group(body.get("group_id"))
            n = self._name_of(body.get("user_id"))
            if g is None or n is None:
                return h.reply(400, {"detail": "No such group or user (GroupDoesNotExist)"})
            members = self.members[g["id"]]
            # is_group_admin: a bool, false when left out (GroupAssociationReq); null is a 422
            if "is_group_admin" in body and not isinstance(body["is_group_admin"], bool):
                return h.reply(422, {"detail": "is_group_admin: a boolean"})
            if method == "POST":
                if n in members:
                    return h.reply(400, {"detail": f"{n} is already in {g['name']} (GroupHasUser)"})
                members[n] = bool(body.get("is_group_admin"))
                self._entry(user, GROUP_ADD_USER, f"{n} added to {g['name']}", path)
            elif method == "DELETE":
                if n not in members:
                    return h.reply(400, {"detail": f"{n} is not in {g['name']} (GroupMissingUser)"})
                del members[n]
                self._entry(user, GROUP_REMOVE_USER, f"{n} removed from {g['name']}", path)
                return h.reply(200, None)
            else:
                if n not in members:
                    return h.reply(400, {"detail": f"{n} is not in {g['name']} (GroupMissingUser)"})
                members[n] = bool(body.get("is_group_admin"))
            return h.reply(200, {"id": 1000 + g["id"] * 10 + self._id(n), "metadata_id": None,
                                 "group_id": g["id"], "user_id": self._id(n),
                                 "is_group_admin": members[n]})
        if route == "/invite/mode":
            if method == "PUT":
                want = (h.json_body() or {}).get("invite_only")
                if not isinstance(want, bool):  # InviteOnlyModeRequest: a required bool
                    return h.reply(422, {"detail": "invite_only: a boolean"})
                self.invite_only = want
                self._entry(user, SETTING_CHANGE, f"invite_only={self.invite_only}", path)
            return h.reply(200, {"invite_only": self.invite_only})
        if route == "/invite/codes" and method == "GET":
            codes = [c for c in self.invites if c["creator_user_id"] == self._id(user)
                     and (c["is_active"] or _flag(query, "include_inactive"))]
            limit = min(int(_q(query, "limit", "50")), 100)
            offset = int(_q(query, "offset", "0"))
            return h.reply(200, {"codes": codes[offset:offset + limit], "total_count": len(codes),
                                 "limit": limit, "offset": offset})
        if route == "/invite/codes" and method == "POST":
            body = h.json_body() or {}
            uses = body.get("max_uses")
            if uses is not None and (not isinstance(uses, int) or uses < 1):
                return h.reply(422, {"detail": "max_uses: at least 1"})
            c = {"id": self.next_invite, "code": f"NEW-{self.next_invite:04d}",
                 "creator_user_id": self._id(user), "max_uses": uses, "use_count": 0,
                 "is_active": True, "created_at": "2026-10-31T09:00:00", "expires_at": None,
                 "note": body.get("note")}
            self.next_invite += 1
            self.invites.insert(0, c)
            return h.reply(200, c)
        if invite_one:
            parts = path.split("/")  # ['', 'invite', 'codes', ID, ...]
            c = next((c for c in self.invites if c["id"] == int(parts[3])), None)
            if c is None:
                return h.reply(404, {"detail": "Invite code not found"})
            rest = "/".join(parts[4:])
            if method == "DELETE" and rest == "":
                c["is_active"] = False
            elif method == "POST" and rest == "reactivate":
                c["is_active"] = True
            elif not (method == "GET" and rest == ""):
                return h.reply(404, {"detail": "Not Found"})
            return h.reply(200, c)
        if route == "/logs":
            entries = self.log if _flag(query, "order_desc", True) else list(reversed(self.log))
            code = _q(query, "event_code")
            if code:
                entries = [e for e in entries if e["event_code"] == int(code)]
            limit = min(int(_q(query, "limit", "50")), 100)
            offset = int(_q(query, "offset", "0"))
            page = [dict(e, user_id=self._id(e["username"]) if e["username"] else None,
                         auth_user_id=None, referrer=None, user_agent="stub",
                         remote_addr="10.0.0.2" if e["username"] else None)
                    for e in entries[offset:offset + limit]]
            return h.reply(200, {"entries": page, "total_count": len(entries), "limit": limit,
                                 "offset": offset})
        if route.startswith("/site/") and method == "PUT":
            key = route[len("/site/"):]
            field = {"title": "title", "description": "description", "timezone": "timezone"}[key]
            value = (h.json_body() or {}).get(field)
            if not isinstance(value, str):
                return h.reply(422, {"detail": f"{field}: a string"})
            self.site[key] = value
            self._entry(user, SETTING_CHANGE, f"site {key} changed", path)
            return h.reply(200, {"message": f"{key} updated", "code": 0, "data": None})
        return h.reply(404, {"detail": "Not Found"})
