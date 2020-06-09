/**
	Web admin interface implementation

	Copyright: © 2015-2017 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module userman.webadmin;

public import userman.api;
import userman.userman : validateUserName;

import vibe.core.log;
import vibe.http.router;
import vibe.textfilter.urlencode;
import vibe.utils.validation;
import vibe.web.auth;
import vibe.web.web;

import std.algorithm : min, max;
import std.array : appender;
import std.conv : to;
import std.exception;
import std.typecons : Nullable;


/**
	Registers the routes for a UserMan web admin interface.
*/
void registerUserManWebAdmin(URLRouter router, UserManAPI api)
{
	router.registerWebInterface(new UserManWebAdminInterface(api));
}

/// private
@requiresAuth
@translationContext!TranslationContext
class UserManWebAdminInterface {
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

	@noAuth
	void getLogin(string redirect = "/", string _error = null)
	{
		bool first_user = m_api.users.count == 0;
		string error = _error;
		render!("userman.admin.login.dt", first_user, error, redirect);
	}

	@noAuth @errorDisplay!getLogin
	void postLogin(string name, string password, string redirect = "/")
	{
		import std.algorithm.searching : canFind;

		User.ID uid;
		try uid = m_api.users.testLogin(name, password);
		catch (Exception e) {
			import std.encoding : sanitize;
			logDebug("Error logging in: %s", e.toString().sanitize);
			throw new Exception("Invalid user/email or password.");
		}

		auto user = m_api.users[uid].get();
		enforce(user.active, "The account is not yet activated.");
		enforce(m_api.users[uid].getGroups().canFind(adminGroupName), "User is not an administrator.");

		m_authUser = user.id;
		m_authUserDisplayName = user.fullName;
		.redirect(redirect);
	}

	@noAuth @errorDisplay!getLogin
	void postInitialRegister(string username, ValidEmail email, string full_name, ValidPassword password, Confirm!"password" password_confirmation, string redirect = "/")
	{
		auto err = appender!string();
		enforceHTTP(m_api.settings.userNameSettings.validateUserName(err, username), HTTPStatus.badRequest, err.data);

		enforceHTTP(m_api.users.count == 0, HTTPStatus.forbidden, "Cannot create initial admin account when other accounts already exist.");
		try m_api.groups[adminGroupName].get();
		catch (Exception) m_api.groups.create(adminGroupName, "UserMan Administrators");

		auto uid = m_api.users.register(email, username, full_name, password);
		m_api.groups[adminGroupName].members.add(uid);
		m_authUser = uid;
		.redirect(redirect);
	}

	@noAuth void getLogout()
	{
		terminateSession();
		redirect("/");
	}


	// everything below requires authentication
	@anyAuth:

	void get(AuthInfo auth)
	{
		render!("userman.admin.index.dt");
	}

	/*********/
	/* Users */
	/**************************************************************************/

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

	@errorDisplay!getUsers
	void postUsers(AuthInfo auth, string name, ValidEmail email, string full_name, ValidPassword password, Confirm!"password" password_confirmation)
	{
		auto err = appender!string();
		enforceHTTP(m_api.settings.userNameSettings.validateUserName(err, name), HTTPStatus.badRequest, err.data);

		m_api.users.register(email, name, full_name, password);
		redirect("users");
	}

	@path("/users/multi") @errorDisplay!getUsers
	void postMultiUserUpdate(AuthInfo auth, string action, HTTPServerRequest req, /*User.ID[] selection,*/ int page = 1)
	{
		import std.algorithm : map;
		foreach (u; /*selection*/req.form.getAll("selection").map!(id => User.ID.fromString(id)))
			performUserAction(u, action);
		redirect(page > 1 ? "/users?page="~page.to!string : "/users");
	}

	@path("/users/:user/")
	void getUser(AuthInfo auth, User.ID _user, string _error = null)
	{
		import vibe.data.json : Json;

		static struct Info {
			User user;
			Json[string] userProperties;
			string error;
		}
		Info info;
		info.user = m_api.users[_user].get();
		info.userProperties = m_api.users[_user].properties.get();
		info.error = _error;
		render!("userman.admin.user.dt", info);
	}

	@path("/users/:user/") @errorDisplay!getUser
	void postUser(AuthInfo auth, User.ID _user, string username, ValidEmail email, string full_name, bool active, bool banned)
	{
		auto err = appender!string();
		enforceHTTP(m_api.settings.userNameSettings.validateUserName(err, username), HTTPStatus.badRequest, err.data);

		//m_api.users[_user].setName(username); // TODO!
		m_api.users[_user].setEmail(email);
		m_api.users[_user].setFullName(full_name);
		m_api.users[_user].setActive(active);
		m_api.users[_user].setBanned(banned);
		redirect("/users/"~_user.toString~"/");
	}

	@path("/users/:user/password") @errorDisplay!getUser
	void postUserPassword(AuthInfo auth, User.ID _user, ValidPassword password, Confirm!"password" password_confirmation)
	{
		m_api.users[_user].setPassword(password);
		redirect("/users/"~_user.toString~"/");
	}

	@path("/users/:user/set_property") @errorDisplay!getUser
	void postSetUserProperty(AuthInfo auth, User.ID _user, Nullable!string old_name, string name, string value)
	{
		import vibe.data.json : parseJson;

		if (!old_name.isNull() && old_name.get != name)
			m_api.users[_user].properties[old_name.get].remove();
		if (name.length) m_api.users[_user].properties[name].set(parseJson(value));
		redirect("./");
	}

	/**********/
	/* Groups */
	/**************************************************************************/

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

	@errorDisplay!getGroups
	void postGroups(AuthInfo auth, ValidGroupName name, string description)
	{
		m_api.groups.create(name, description);
		redirect("/groups/"~name~"/");
	}

	@path("/groups/multi") @errorDisplay!getGroups
	void postMultiGroupUpdate(AuthInfo auth, string action, HTTPServerRequest req, /*User.ID[] selection,*/ int page = 1)
	{
		import std.algorithm : map;
		foreach (g; /*selection*/req.form.getAll("selection"))
			performGroupAction(g, action);
		redirect(page > 1 ? "/groups?page="~page.to!string : "/groups");
	}

	@path("/groups/:group/")
	void getGroup(AuthInfo auth, string _group, string _error = null)
	{
		static struct Info {
			Group group;
			long memberCount;
			string error;
		}
		Info info;
		info.group = m_api.groups[_group].get();
		info.memberCount = m_api.groups[_group].members.count();
		info.error = _error;
		render!("userman.admin.group.dt", info);
	}

	@path("/groups/:group/") @errorDisplay!getGroup
	void postGroup(AuthInfo auth, string _group, string description)
	{
		m_api.groups[_group].setDescription(description);
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

	@path("/groups/:group/members/")
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
		info.group = m_api.groups[_group].get();
		info.page = page;
		info.pageCount = ((m_api.groups.count + m_entriesPerPage - 1) / m_entriesPerPage).to!int;
		info.members = m_api.groups[_group].members.getRange((page-1) * m_entriesPerPage, m_entriesPerPage)
			.map!(id => m_api.users[id].get())
			.array;
		info.error = _error;
		render!("userman.admin.group.members.dt", info);
	}

	@path("/groups/:group/members/:user/remove") @errorDisplay!getGroupMembers
	void postRemoveMember(AuthInfo auth, string _group, User.ID _user)
	{
		enforce(_group != adminGroupName || _user != auth.user.id,
			"Cannot remove yourself from the admin group.");
		m_api.groups[_group].members[_user].remove();
		redirect("/groups/"~_group~"/members/");
	}

	@path("/groups/:group/members/") @errorDisplay!getGroupMembers
	void postAddMember(AuthInfo auth, string _group, string username)
	{
		auto uid = m_api.users.getByName(username).id;
		m_api.groups[_group].members.add(uid);
		redirect("/groups/"~_group~"/members/");
	}

	/************/
	/* Settings */
	/**************************************************************************/

	@path("/settings/")
	void getSettings(AuthInfo auth, string _error = null)
	{
		struct Info {
			string error;
			UserManAPISettings settings;
		}

		Info info;
		info.error = _error;
		info.settings = m_api.settings;
		render!("userman.admin.settings.dt", info);
	}

	@path("/settings/") @errorDisplay!getSettings
	void posttSettings(AuthInfo auth)
	{
		// TODO!
		redirect("/settings/");
	}

	private void performUserAction(User.ID user, string action)
	{
		switch (action) {
			default: throw new Exception("Unknown action: "~action);
			case "activate": m_api.users[user].setActive(true); break;
			case "deactivate": m_api.users[user].setActive(false); break;
			case "ban": m_api.users[user].setBanned(true); break;
			case "unban": m_api.users[user].setBanned(false); break;
			case "delete": m_api.users[user].remove(); break;
			case "sendActivation":
				auto email = m_api.users[user].get().email;
				m_api.users.resendActivation(email);
				break;
		}
	}

	private void performGroupAction(string group, string action)
	{
		switch (action) {
			default: throw new Exception("Unknown action: "~action);
			case "delete":
				enforce(group != adminGroupName, "Cannot remove admin group.");
				m_api.groups[group].remove();
				break;
		}
	}

	@noRoute AuthInfo authenticate(HTTPServerRequest req, HTTPServerResponse res)
	@trusted {
		if (m_authUser == User.ID.init) {
			redirect("/login?redirect="~req.path.urlEncode);
			return AuthInfo.init;
		} else {
			return AuthInfo(m_api.users[m_authUser].get());
		}
	}
}

private struct AuthInfo {
	User user;
}

private struct TranslationContext {
	import std.meta : AliasSeq;
	alias languages = AliasSeq!("en_US", "de_DE");
	//mixin translationModule!"userman";
}

struct ValidGroupName {
	string m_value;

	@disable this();

	private this(string value) { m_value = value; }

	static Nullable!ValidGroupName fromStringValidate(string str, string* err)
	{
		import vibe.utils.validation : validateIdent;
		import std.algorithm : splitter;
		import std.array : appender;

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
