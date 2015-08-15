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
	}

	this(UserManAPI api)
	{
		m_api = api;
	}

	void getLogin(string _error = null)
	{
		bool first_user = m_api.users.count == 0;
		string error = _error;
		render!("userman.admin.login.dt", first_user, error);
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

		m_authUser = user.id;
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
	void getUsers(AuthInfo auth, int page = 1)
	{
		static struct Info {
			User[] users;
			int pageCount;
			int page;
		}

		Info info;
		info.page = page;
		info.pageCount = ((m_api.users.count + m_entriesPerPage - 1) / m_entriesPerPage).to!int;
		info.users = m_api.users.get((page-1) * m_entriesPerPage, m_entriesPerPage);
		render!("userman.admin.users.dt", info);
	}

	@auth
	void getGroups(AuthInfo auth, int page = 1)
	{
		static struct Info {
			Group[] groups;
			int pageCount;
			int page;
		}

		Info info;
		info.page = page;
		//info.pageCount = ((m_api.users.count + m_entriesPerPage - 1) / m_entriesPerPage).to!int;
		//info.groups = m_api.groups.get((page-1) * m_entriesPerPage, m_entriesPerPage);
		render!("userman.admin.groups.dt", info);
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
