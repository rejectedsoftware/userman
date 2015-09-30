/**
	Web admin interface implementation

	Copyright: © 2015 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module userman.webadmin;

public import userman.api;

import vibe.core.log;
import vibe.crypto.passwordhash;
import vibe.http.router;
import vibe.textfilter.urlencode;
import vibe.utils.validation;
import vibe.web.web;

import std.algorithm : min, max;
import std.conv : to;
import std.exception;


/**
	Registers the routes for a UserMan web admin interface.
*/
void registerUserManWebAdmin(URLRouter router, UserManAPI api)
{
	router.registerWebInterface(new UserManWebAdminInterface(api));
}

private class UserManWebAdminInterface {
	enum adminGroupName = "userman.admins";

	private {
		UserManAPI m_api;
		int m_entriesPerPage = 50;
		SessionVar!(User.ID, "authUser") m_authUser;
		SessionVar!(string, "authUserDisplayName") m_authUserDisplayName;
	}

	this(UserManAPI api)
	{
		m_api = api;
	}

	void getLogin(string redirect = "/", string _error = null)
	{
		bool first_user = m_api.users.count == 0;
		string error = _error;
		render!("userman.admin.login.dt", first_user, error, redirect);
	}

	@errorDisplay!getLogin
	void postLogin(string name, string password, string redirect = "/")
	{
		User.ID uid;
		try uid = m_api.users.testLogin(name, password);
		catch (Exception e) {
			logDebug("Error logging in: %s", e.toString().sanitize);
			throw new Exception("Invalid user/email or password.");
		}

		auto user = m_api.users.get(uid);
		enforce(user.active, "The account is not yet activated.");
		enforce(user.groups.canFind(adminGroupName), "User is not an administrator.");

		m_authUser = user.id;
		m_authUserDisplayName = user.fullName;
		.redirect(redirect);
	}

	@errorDisplay!getLogin
	void postInitialRegister(ValidUsername username, ValidEmail email, string full_name, ValidPassword password, Confirm!"password" password_confirmation, string redirect = "/")
	{
		enforceHTTP(m_api.users.count == 0, HTTPStatus.forbidden, "Cannot create initial admin account when other accounts already exist.");
		try m_api.groups.get(adminGroupName);
		catch (Exception) m_api.groups.create(adminGroupName, "UserMan Administrators");

		auto uid = m_api.users.register(email, username, full_name, password);
		m_api.groups.addMember(adminGroupName, uid);
		m_authUser = uid;
		.redirect(redirect);
	}

	void getLogout()
	{
		terminateSession();
		redirect("/");	
	}

	@auth
	void get(AuthInfo auth)
	{
		render!("userman.admin.index.dt");
	}

	@auth
	void getUsers(AuthInfo auth, int page = 1, string _error = null)
	{
		static struct Info {
			User[] users;
			int pageCount;
			int page;
			string error;
		}

		Info info;
		info.page = page;
		info.pageCount = ((m_api.users.count + m_entriesPerPage - 1) / m_entriesPerPage).to!int;
		info.users = m_api.users.getRange((page-1) * m_entriesPerPage, m_entriesPerPage);
		info.error = _error;
		render!("userman.admin.users.dt", info);
	}

	@auth @errorDisplay!getUsers
	void postUsers(AuthInfo auth, ValidUsername name, ValidEmail email, string full_name, ValidPassword password, Confirm!"password" password_confirmation)
	{
		m_api.users.register(email, name, full_name, password);
		redirect("users");
	}

	@auth @path("/users/multi") @errorDisplay!getUsers
	void postMultiUserUpdate(AuthInfo auth, string action, HTTPServerRequest req, /*User.ID[] selection,*/ int page = 1)
	{
		import std.algorithm : map;
		foreach (u; /*selection*/req.form.getAll("selection").map!(id => User.ID.fromString(id)))
			performUserAction(u, action);
		redirect(page > 1 ? "/users?page="~page.to!string : "/users");
	}

	@auth @path("/users/:user/")
	void getUser(AuthInfo auth, User.ID _user, string _error = null)
	{
		static struct Info {
			User user;
			string error;
		}
		Info info;
		info.user = m_api.users.get(_user);
		info.error = _error;
		render!("userman.admin.user.dt", info);
	}

	@auth @path("/users/:user/") @errorDisplay!getUser
	void postUser(AuthInfo auth, User.ID _user, ValidUsername username, ValidEmail email, string full_name, bool active, bool banned)
	{
		//m_api.users.setName(_user, username); // TODO!
		m_api.users.setEmail(_user, email);
		m_api.users.setFullName(_user, full_name);
		m_api.users.setActive(_user, active);
		m_api.users.setBanned(_user, banned);
		redirect("/users/"~_user.toString~"/");
	}

	@auth @path("/users/:user/password") @errorDisplay!getUser
	void postUserPassword(AuthInfo auth, User.ID _user, ValidPassword password, Confirm!"password" password_confirmation)
	{
		m_api.users.setPassword(_user, password);
		redirect("/users/"~_user.toString~"/");
	}

	@auth @path("/users/:user/set_property") @errorDisplay!getUser
	void postSetUserProperty(AuthInfo auth, User.ID _user, Nullable!string old_name, string name, string value)
	{
		import vibe.data.json : parseJson;

		if (!old_name.isNull() && old_name != name)
			m_api.users.removeProperty(_user, old_name);
		if (name.length) m_api.users.setProperty(_user, name, parseJson(value));
		redirect("./");
	}

	@auth
	void getGroups(AuthInfo auth, long page = 1, string _error = null)
	{
		static struct Info {
			Group[] groups;
			long pageCount;
			long page;
			string error;
		}

		Info info;
		info.page = page;
		info.pageCount = (m_api.groups.count + m_entriesPerPage - 1) / m_entriesPerPage;
		info.groups = m_api.groups.getRange((page-1) * m_entriesPerPage, m_entriesPerPage);
		info.error = _error;
		render!("userman.admin.groups.dt", info);
	}

	@auth @errorDisplay!getGroups
	void postGroups(AuthInfo auth, ValidGroupName name, string description)
	{
		m_api.groups.create(name, description);
		redirect("/groups/"~name~"/");
	}

	@auth @path("/groups/multi") @errorDisplay!getGroups
	void postMultiGroupUpdate(AuthInfo auth, string action, HTTPServerRequest req, /*User.ID[] selection,*/ int page = 1)
	{
		import std.algorithm : map;
		foreach (g; /*selection*/req.form.getAll("selection"))
			performGroupAction(g, action);
		redirect(page > 1 ? "/groups?page="~page.to!string : "/groups");
	}

	@auth @path("/groups/:group/")
	void getGroup(AuthInfo auth, string _group, string _error = null)
	{
		static struct Info {
			Group group;
			long memberCount;
			string error;
		}
		Info info;
		info.group = m_api.groups.get(_group);
		info.memberCount = m_api.groups.getMemberCount(_group);
		info.error = _error;
		render!("userman.admin.group.dt", info);
	}

	@auth @path("/groups/:group/") @errorDisplay!getGroup
	void postGroup(AuthInfo auth, string _group, string description)
	{
		m_api.groups.setDescription(_group, description);
		redirect("/groups/"~_group~"/");
	}

	/*@auth @path("/group/:group/set_property") @errorDisplay!getGroup
	void postSetGroupProperty(AuthInfo auth, string _group, Nullable!string old_name, string name, string value)
	{
		import vibe.data.json : parseJson;

		if (!old_name.isNull() && old_name != name)
			m_api.groups.removeProperty(_group, old_name);
		if (name.length) m_api.groups.setProperty(_group, name, parseJson(value));
		redirect("./");
	}*/

	@auth @path("/groups/:group/members/")
	void getGroupMembers(AuthInfo auth, string _group, long page = 1, string _error = null)
	{
		import std.algorithm : map;
		import std.array : array;

		static struct Info {
			Group group;
			User[] members;
			long page;
			long pageCount;
			string error;
		}
		Info info;
		info.group = m_api.groups.get(_group);
		info.page = page;
		info.pageCount = ((m_api.groups.count + m_entriesPerPage - 1) / m_entriesPerPage).to!int;
		info.members = m_api.groups.getMemberRange(_group, (page-1) * m_entriesPerPage, m_entriesPerPage)
			.map!(id => m_api.users.get(id))
			.array;
		info.error = _error;
		render!("userman.admin.group.members.dt", info);
	}

	@auth @path("/groups/:group/members/:user/remove") @errorDisplay!getGroupMembers
	void postRemoveMember(AuthInfo auth, string _group, User.ID _user)
	{
		enforce(_group != adminGroupName || _user != auth.user.id,
			"Cannot remove yourself from the admin group.");
		m_api.groups.removeMember(_group, _user);
		redirect("/groups/"~_group~"/members/");
	}

	@auth @path("/groups/:group/members/") @errorDisplay!getGroupMembers
	void postAddMember(AuthInfo auth, string _group, string username)
	{
		auto uid = m_api.users.getByName(username).id;
		m_api.groups.addMember(_group, uid);
		redirect("/groups/"~_group~"/members/");
	}

	private void performUserAction(User.ID user, string action)
	{
		switch (action) {
			default: throw new Exception("Unknown action: "~action);
			case "activate": m_api.users.setActive(user, true); break;
			case "deactivate": m_api.users.setActive(user, false); break;
			case "ban": m_api.users.setBanned(user, true); break;
			case "unban": m_api.users.setBanned(user, false); break;
			case "delete": m_api.users.remove(user); break;
			case "sendActivation": m_api.users.resendActivation(user); break;
		}
	}

	private void performGroupAction(string group, string action)
	{
		switch (action) {
			default: throw new Exception("Unknown action: "~action);
			case "delete":
				enforce(group != adminGroupName, "Cannot remove admin group.");
				m_api.groups.remove(group);
				break;
		}
	}

	mixin PrivateAccessProxy;
	enum auth = before!handleAuth("auth");
	private AuthInfo handleAuth(HTTPServerRequest req, HTTPServerResponse res)
	{
		if (m_authUser == User.ID.init) {
			redirect("/login?redirect="~req.path.urlEncode);
			return AuthInfo.init;
		} else {
			return AuthInfo(m_api.users.get(m_authUser));
		}
	}
}

private struct AuthInfo {
	User user;
}

struct ValidGroupName {
	string m_value;

	@disable this();

	private this(string value) { m_value = value; }

	static Nullable!ValidGroupName fromStringValidate(string str, string* err)
	{
		import vibe.utils.validation : validateIdent;
		import std.algorithm : splitter;

		// work around disabled default construction
		auto ret = Nullable!ValidGroupName(ValidGroupName(null));
		ret.nullify();

		if (str.length < 1) {
			*err = "Group names must not be empty.";
			return ret;
		}
		auto errapp = appender!string;
		foreach (p; str.splitter(".")) {
			if (!validateIdent(errapp, p)) {
				*err = errapp.data;
				return ret;
			}
		}

		ret = ValidGroupName(str);
		return ret;
	}

	string toString() const { return m_value; }

	alias toString this;
}