/**
	Web interface implementation

	Copyright: © 2012-2017 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module userman.web;

public import userman.api;
import userman.db.controller : UserManController;
import userman.userman : validateUserName;

import vibe.core.log;
import vibe.crypto.passwordhash;
import vibe.http.router;
import vibe.textfilter.urlencode;
import vibe.utils.validation;
import vibe.web.auth;
import vibe.web.web;

import std.array : appender;
import std.exception;
import std.typecons : Nullable;


/**
	Registers the routes for a UserMan web interface.

	Use this to add user management to your web application. See also
	$(D UserManWebAuthenticator) for some complete examples of a simple
	web service with UserMan integration.
*/
void registerUserManWebInterface(URLRouter router, UserManAPI api)
{
	router.registerWebInterface(new UserManWebInterface(api));
}
/// deprecated
void registerUserManWebInterface(URLRouter router, UserManController controller)
{
	router.registerUserManWebInterface(createLocalUserManAPI(controller));
}


/**
	Helper function to update the user profile from a POST request.

	This assumes that the fields are named like they are in userman.profile.dt.
	Session variables will be updated automatically.
*/
void updateProfile(UserManAPI api, User.ID user, HTTPServerRequest req)
{
	/*if (api.settings.useUserNames) {
		if (auto pv = "name" in req.form) {
			api.users.setName(user, *pv);
			req.session.set("userName", *pv);
		}
	}*/ // TODO!
	if (auto pv = "email" in req.form) {
		api.users[user].setEmail(*pv);
		req.session.set("userEmail", *pv);
	}
	if (auto pv = "full_name" in req.form) {
		api.users[user].setFullName(*pv);
		req.session.set("userFullName", *pv);
	}
	if (auto pv = "password" in req.form) {
		auto pconf = "password_confirmation" in req.form;
		enforce(pconf !is null, "Missing password confirmation.");
		validatePassword(*pv, *pconf);
		api.users[user].setPassword(*pv);
	}
}
/// ditto
deprecated void updateProfile(UserManController controller, User user, HTTPServerRequest req)
{
	updateProfile(createLocalUserManAPI(controller), user.id, req);
}


/**
	Used to provide request authentication for web applications.

	Note that it is generally recommended to use the `vibe.web.auth` mechanism
	together with `authenticate` instead of using this class.

	See_also: `authenticate`
*/
class UserManWebAuthenticator {
	private {
		UserManAPI m_api;
		string m_prefix;
	}

	this(UserManAPI api, string prefix = "/")
	{
		m_api = api;
		m_prefix = prefix;
	}

	deprecated this(UserManController controller, string prefix = "/")
	{
		this(createLocalUserManAPI(controller), prefix);
	}

	HTTPServerRequestDelegate auth(void delegate(HTTPServerRequest, HTTPServerResponse, User) callback)
	{
		void requestHandler(HTTPServerRequest req, HTTPServerResponse res)
		@trusted {
			User usr;
			try usr = performAuth(req, res);
			catch (Exception e) throw new HTTPStatusException(HTTPStatus.unauthorized);
			if (res.headerWritten) return;
			callback(req, res, usr);
		}

		return &requestHandler;
	}
	HTTPServerRequestDelegate auth(HTTPServerRequestDelegate callback)
	{
		return auth((req, res, user){ callback(req, res); });
	}

	User performAuth(HTTPServerRequest req, HTTPServerResponse res)
	{
		if (!req.session) {
			res.redirect(m_prefix~"login?redirect="~urlEncode(req.path));
			return User.init;
		} else {
			return m_api.users.getByName(req.session.get!string("userName"));
		}
	}

	HTTPServerRequestDelegate ifAuth(void delegate(HTTPServerRequest, HTTPServerResponse, User) callback)
	{
		void requestHandler(HTTPServerRequest req, HTTPServerResponse res)
		@trusted {
			if( !req.session ) return;
			auto usr = m_api.users.getByName(req.session.get!string("userName"));
			callback(req, res, usr);
		}

		return &requestHandler;
	}
}

/** An example using a plain $(D vibe.http.router.URLRouter) based
	authentication approach.
*/
unittest {
	import std.functional; // toDelegate
	import vibe.http.router;
	import vibe.http.server;

	void getIndex(HTTPServerRequest req, HTTPServerResponse res)
	{
		//render!"welcome.dt"
	}

	void getPrivatePage(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		// render a private page with some user specific information
		//render!("private_page.dt", _user);
	}

	void registerMyService(URLRouter router, UserManAPI userman)
	{
		auto authenticator = new UserManWebAuthenticator(userman);
		router.registerUserManWebInterface(userman);
		router.get("/", &getIndex);
		router.any("/private_page", authenticator.auth(toDelegate(&getPrivatePage)));
	}
}


/** Ensures that a user is logged in.

	If a valid session exists, the returned `User` object will contain all
	information about the logged in user. Otherwise, the response object will
	be used to redirect the user to the login page and an empty user object
	is returned.

	Params:
		req = The request object of the incoming request
		res = The response object of the incoming request
		api = A reference to the UserMan API
		url_prefix = Optional prefix to prepend to the login page path
*/
User authenticate(HTTPServerRequest req, HTTPServerResponse res, UserManAPI api, string url_prefix = "")
@trusted {
	if (!req.session) {
		res.redirect(url_prefix~"login?redirect="~urlEncode(req.path));
		return User.init;
	} else {
		return api.users.getByName(req.session.get!string("userName"));
	}
}

/** This example uses the $(D @before) annotation supported by the
	$(D vibe.web.web) framework for a concise and statically defined
	authentication approach.
*/
unittest {
	import vibe.http.router;
	import vibe.http.server;
	import vibe.web.web;

	@requiresAuth
	class MyWebService {
		private {
			UserManAPI m_api;
		}

		this(UserManAPI userman)
		{
			m_api = userman;
		}

		// this route can be accessed publicly (/)
		@noAuth
		void getIndex()
		{
			//render!"welcome.dt"
		}

		// the @authenticated attribute (defined below) ensures that this route
		// (/private_page) can only ever be accessed if the user is logged in
		@anyAuth
		void getPrivatePage(User user)
		{
			// render a private page with some user specific information
			//render!("private_page.dt", user);
		}

		@noRoute User authenticate(HTTPServerRequest req, HTTPServerResponse res)
		{
			return .authenticate(req, res, m_api);
		}
	}

	void registerMyService(URLRouter router, UserManAPI userman)
	{
		router.registerUserManWebInterface(userman);
		router.registerWebInterface(new MyWebService(userman));
	}
}


/** Web interface class for UserMan, suitable for use with $(D vibe.web.web).

	The typical approach is to use $(D registerUserManWebInterface) instead of
	directly using this class.
*/
@requiresAuth
@translationContext!TranslationContext
class UserManWebInterface {
	private {
		UserManAPI m_api;
		string m_prefix;
		SessionVar!(string, "userEmail") m_sessUserEmail;
		SessionVar!(string, "userName") m_sessUserName;
		SessionVar!(string, "userFullName") m_sessUserFullName;
		SessionVar!(string, "userID") m_sessUserID;
		UserManAPISettings m_settings;
	}

	this(UserManAPI api, string prefix = "/")
	{
		m_api = api;
		m_settings = api.settings;
		m_prefix = prefix;
	}

	deprecated this(UserManController controller, string prefix = "/")
	{
		this(createLocalUserManAPI(controller), prefix);
	}

	@noAuth
	void getLogin(string redirect = "", string _error = "")
	{
		string error = _error;
		auto settings = m_settings;
		render!("userman.login.dt", error, redirect, settings);
	}

	@noAuth @errorDisplay!getLogin
	void postLogin(string name, string password, string redirect = "")
	{
		User user;
		try {
			auto uid = m_api.users.testLogin(name, password);
			user = m_api.users[uid].get();
		} catch (Exception e) {
			import std.encoding : sanitize;
			logDebug("Error logging in: %s", e.toString().sanitize);
			throw new Exception("Invalid user/email or password.");
		}

		enforce(user.active, "The account is not yet activated.");

		m_sessUserEmail = user.email;
		m_sessUserName = user.name;
		m_sessUserFullName = user.fullName;
		m_sessUserID = user.id.toString();
		.redirect(redirect.length ? redirect : m_prefix);
	}

	@noAuth
	void getLogout(HTTPServerResponse res)
	{
		terminateSession();
		res.headers["Refresh"] = "3; url="~m_settings.serviceURL.toString();
		render!("userman.logout.dt");
	}

	@noAuth
	void getRegister(string _error = "")
	{
		string error = _error;
		auto settings = m_settings;
		render!("userman.register.dt", error, settings);
	}

	@noAuth @errorDisplay!getRegister
	void postRegister(ValidEmail email, Nullable!string name, string fullName, ValidPassword password, Confirm!"password" passwordConfirmation)
	{
		string username;
		if (m_settings.useUserNames) {
			enforce(!name.isNull, "Missing user name field.");

			auto err = appender!string();
			enforce(m_settings.userNameSettings.validateUserName(err, name), err.data);

			username = name;
		} else username = email;

		m_api.users.register(email, username, fullName, password);

		if (m_settings.requireActivation) {
			string error;
			render!("userman.register_activate.dt", error);
		} else {
			postLogin(username, password);
		}
	}

	@noAuth
	void getResendActivation(string _error = "")
	{
		string error = _error;
		render!("userman.resend_activation.dt", error);
	}

	@noAuth @errorDisplay!getResendActivation
	void postResendActivation(ValidEmail email)
	{
		try {
			m_api.users.resendActivation(email);
			render!("userman.resend_activation_done.dt");
		} catch (Exception e) {
			import std.encoding : sanitize;
			logDebug("Error sending activation mail: %s", e.toString().sanitize);
			throw new Exception("Failed to send activation mail. Please try again later. ("~e.msg~").");
		}
	}

	@noAuth
	void getActivate(ValidEmail email, string code)
	{
		m_api.users.activate(email, code);
		auto user = m_api.users.getByEmail(email);
		m_sessUserEmail = user.email;
		m_sessUserName = user.name;
		m_sessUserFullName = user.fullName;
		m_sessUserID = user.id.toString();
		render!("userman.activate.dt");
	}

	@noAuth
	void getForgotLogin(string _error = "")
	{
		auto error = _error;
		render!("userman.forgot_login.dt", error);
	}

	@noAuth @errorDisplay!getForgotLogin
	void postForgotLogin(ValidEmail email)
	{
		try {
			m_api.users.requestPasswordReset(email);
		} catch(Exception e) {
			// ignore errors, so that registered e-mails cannot be determined
			logDiagnostic("Failed to send password reset mail to %s: %s", email, e.msg);
		}

		render!("userman.forgot_login_sent.dt");
	}

	@noAuth
	void getResetPassword(string _error = "")
	{
		string error = _error;
		render!("userman.reset_password.dt", error);
	}

	@noAuth @errorDisplay!getResetPassword
	void postResetPassword(ValidEmail email, string code, ValidPassword password, Confirm!"password" password_confirmation, HTTPServerResponse res)
	{
		m_api.users.resetPassword(email, code, password);
		res.headers["Refresh"] = "3; url=" ~ m_settings.serviceURL.toString();
		render!("userman.reset_password_done.dt");
	}

	@anyAuth
	void getProfile(HTTPServerRequest req, User _user, string _error = "")
	{
		req.form["full_name"] = _user.fullName;
		req.form["email"] = _user.email;
		bool useUserNames = m_settings.useUserNames;
		auto user = _user;
		string error = _error;
		render!("userman.profile.dt", user, useUserNames, error);
	}

	@anyAuth @errorDisplay!getProfile
	void postProfile(HTTPServerRequest req, User _user)
	{
		updateProfile(m_api, _user.id, req);
		redirect(m_prefix);
	}

	@noRoute User authenticate(HTTPServerRequest req, HTTPServerResponse res)
	{
		return .authenticate(req, res, m_api, m_prefix);
	}
}

private struct TranslationContext {
	import std.meta : AliasSeq;
	alias languages = AliasSeq!("en_US", "de_DE");
	//mixin translationModule!"userman";
}
