/**
	Local and REST API access.

	Copyright: © 2015-2016 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module userman.api;

import userman.db.controller;

import vibe.data.json : Json;
import vibe.http.router;
import vibe.web.rest;

/**
	Registers a RESTful interface to the UserMan API on the given router.
*/
void registerUserManRestInterface(URLRouter router, UserManController ctrl)
{
	router.registerRestInterface(new UserManAPIImpl(ctrl));
}

/**
	Returns an API instance for accessing a process local UserMan instance.
*/
UserManAPI createLocalUserManAPI(UserManController ctrl)
{
	return new UserManAPIImpl(ctrl);
}

/**
	Returns an API instance for accessing a RESTful remove UserMan instance.
*/
RestInterfaceClient!UserManAPI createUserManRestAPI(URL base_url)
{
	return new RestInterfaceClient!UserManAPI(base_url);
}


/// Root entry point for the UserMan API
interface UserManAPI {
	/// Interface suitable for manipulating user information
	@property Collection!UserManUserAPI users();

	/// Interface suitable for manipulating group information
	@property Collection!UserManGroupAPI groups();

	@property APISettings settings();
}

struct APISettings {
	bool useUserNames;
	bool requireActivation;
	string serviceName;
	URL serviceURL;
	string serviceEmail;
}

/// Interface suitable for manipulating user information
interface UserManUserAPI {
	struct CollectionIndices {
		User.ID _user;
	}

	/// Gets the total number of registered users.
	@property long count();

	/// Accesses the properties of a user.
	@property Collection!UserManUserPropertyAPI properties(User.ID _user);

	/// Tests a username/e-mail and password combination for validity.
	User.ID testLogin(string name, string password);

	/// Registers a new user.
	User.ID register(string email, string name, string full_name, string password);

	/// Invites a user.
	User.ID invite(string email, string full_name, string message, bool send_mail = true);

	/// Activates a user account using an activation code.
	void activate(string email, string activation_code);

	/// Re-sends an e-mail containing the account activation code.
	void resendActivation(string email);

	/// Sends an e-mail with a password reset code.
	void requestPasswordReset(string email);

	/// Sets a new password using a password reset code.
	void resetPassword(string email, string reset_code, string new_password);

	/// Gets information about a user.
	User get(User.ID _user);

	/// Gets information about a user using the user name as the identifier.
	User getByName(string q);

	/// Gets information about a user using the e-mail address as the identifier.
	User getByEmail(string q);

	/// Gets information about a user using the user name or e-mail address as the identifier.
	User getByEmailOrName(string q);

	/// Gets information about a range of users, suitable for pagination.
	User[] getRange(int first_user, int max_count);

	/// Deletes a user account.
	void remove(User.ID _user);
	//void update(in ref User user);

	/// Updates the e-mail address of a user account.
	void setEmail(User.ID _user, string email);

	/// Updates the display name of a user.
	void setFullName(User.ID _user, string full_name);

	/// Sets a new password.
	void setPassword(User.ID _user, string password);

	/// Sets the activation state of a user.
	void setActive(User.ID _user, bool active);

	/// Sets the banned state of a user.
	void setBanned(User.ID _user, bool banned);

	/// Sets a custom user account property.
	deprecated void setProperty(User.ID _user, string name, Json value);

	/// Removes a user account property.
	deprecated void removeProperty(User.ID _user, string name);

	/// Returns the names of all groups the user is in.
	string[] getGroups(User.ID _user);
}

interface UserManUserPropertyAPI {
	struct CollectionIndices {
		User.ID _user;
		string _name;
	}

	Json[string] get(User.ID _user);
	Json get(User.ID _user, string _name);
	void set(User.ID _user, string _name, Json value);
	void remove(User.ID _user, string _name);
}

struct User {
	alias ID = userman.db.controller.User.ID;
	ID id;
	bool active;
	bool banned;
	string name;
	string fullName;
	string email;
	//string[] groups;
	//Json[string] properties;

	this(userman.db.controller.User usr)
	{
		this.id = usr.id;
		this.active = usr.active;
		this.banned = usr.banned;
		this.name = usr.name;
		this.fullName = usr.fullName;
		this.email = usr.email;
	}
}

/// Interface suitable for manipulating group information
interface UserManGroupAPI {
	struct CollectionIndices {
		string _group;
	}

	Collection!UserManGroupMemberAPI members(string _group);

	/// The total number of groups.
	@property long count();

	/// Creates a new group.
	void create(string name, string description);

	/// Removes a group.
	void remove(string _group);

	/// Gets information about an existing group.
	//Group getByID(Group.ID id);

	/// Sets the description of a group.
	void setDescription(string _group, string description);

	/// Gets information about a group using its name as the identifier.
	Group get(string _group);

	/// Gets a range of groups, suitable for pagination.
	Group[] getRange(long first_group, long max_count);
}

interface UserManGroupMemberAPI {
	struct CollectionIndices {
		string _group;
		User.ID _user;
	}

	/// Gets the number of members of a certain group.
	long count(string _group);

	/// Gets a list of group members, suitable for pagination.
	User.ID[] getRange(string _group, long first_member, long max_count);

	/// Adds a user to a group.
	void add(string _group, User.ID user_id);

	/// Removes a user from a group.
	void remove(string _group, User.ID _user);
}

struct Group {
	string id;
	string description;
	//Json[string] properties;

	this(userman.db.controller.Group grp)
	{
		this.id = grp.id;
		this.description = grp.description;
	}
}

private class UserManAPIImpl : UserManAPI {
	private {
		UserManController m_ctrl;
		UserManUserAPIImpl m_users;
		UserManGroupAPIImpl m_groups;
		APISettings m_settings;
	}

	this(UserManController ctrl)
	{
		m_ctrl = ctrl;
		m_users = new UserManUserAPIImpl(ctrl);
		m_groups = new UserManGroupAPIImpl(ctrl);
		m_settings.useUserNames = ctrl.settings.useUserNames;
		m_settings.requireActivation = ctrl.settings.requireAccountValidation;
		m_settings.serviceName = ctrl.settings.serviceName;
		m_settings.serviceURL = ctrl.settings.serviceUrl;
		m_settings.serviceEmail = ctrl.settings.serviceEmail;
	}

	@property Collection!UserManUserAPI users() { return Collection!UserManUserAPI(m_users); }
	@property Collection!UserManGroupAPI groups() { return Collection!UserManGroupAPI(m_groups); }
	@property APISettings settings() { return m_settings; }
}

private class UserManUserAPIImpl : UserManUserAPI {
	private {
		UserManController m_ctrl;
		UserManUserPropertyAPIImpl m_properties;
	}

	this(UserManController ctrl)
	{
		m_ctrl = ctrl;
		m_properties = new UserManUserPropertyAPIImpl(m_ctrl);
	}

	@property long count()
	{
		return m_ctrl.getUserCount();
	}

	@property Collection!UserManUserPropertyAPI properties(User.ID _id)
	{
		return Collection!UserManUserPropertyAPI(m_properties, _id);
	}

	User.ID testLogin(string name, string password)
	{
		auto ret = m_ctrl.testLogin(name, password);
		enforceHTTP(!ret.isNull, HTTPStatus.unauthorized, "Wrong user name or password.");
		return ret.get();
	}

	User.ID register(string email, string name, string full_name, string password)
	{
		return m_ctrl.registerUser(email, name, full_name, password);
	}

	User.ID invite(string email, string full_name, string message, bool send_mail = true)
	{
		return m_ctrl.inviteUser(email, full_name, message, send_mail);
	}

	void activate(string email, string activation_code)
	{
		m_ctrl.activateUser(email, activation_code);
	}

	void resendActivation(string email)
	{
		m_ctrl.resendActivation(email);
	}

	void requestPasswordReset(string email)
	{
		m_ctrl.requestPasswordReset(email);
	}

	void resetPassword(string email, string reset_code, string new_password)
	{
		m_ctrl.resetPassword(email, reset_code, new_password);
	}

	User get(User.ID id)
	{
		return User(m_ctrl.getUser(id));
	}

	User getByName(string q)
	{
		return User(m_ctrl.getUserByName(q));
	}

	User getByEmail(string q)
	{
		return User(m_ctrl.getUserByEmail(q));
	}

	User getByEmailOrName(string q)
	{
		return User(m_ctrl.getUserByEmailOrName(q));
	}

	User[] getRange(int first_user, int max_count)
	{
		import std.array : appender;
		auto ret = appender!(User[]);
		m_ctrl.enumerateUsers(first_user, max_count, (ref usr) { ret ~= User(usr); });
		return ret.data;
	}

	void remove(User.ID id)
	{
		m_ctrl.deleteUser(id);
	}

	//void update(in ref User user);

	void setEmail(User.ID id, string email)
	{
		m_ctrl.setEmail(id, email);
	}

	void setFullName(User.ID id, string full_name)
	{
		m_ctrl.setFullName(id, full_name);
	}
	
	void setPassword(User.ID id, string password)
	{
		m_ctrl.setPassword(id, password);
	}

	void setActive(User.ID id, bool active)
	{
		// FIXME: efficiency and atomicity
		auto usr = m_ctrl.getUser(id);
		if (usr.active != active) {
			usr.active = active;
			m_ctrl.updateUser(usr);
		}
	}

	void setBanned(User.ID id, bool banned)
	{
		// FIXME: efficiency and atomicity
			import vibe.core.log; logInfo("DO ITMAYBE");
		auto usr = m_ctrl.getUser(id);
		if (usr.banned != banned) {
			usr.banned = banned;
			m_ctrl.updateUser(usr);
			import vibe.core.log; logInfo("DO IT");
		}
	}
	
	void setProperty(User.ID id, string name, Json value)
	{
		m_ctrl.setProperty(id, name, value);
	}

	void removeProperty(User.ID id, string name)
	{
		m_ctrl.removeProperty(id, name);
	}

	string[] getGroups(User.ID id)
	{
		return m_ctrl.getUser(id).groups;
	}
}

private class UserManUserPropertyAPIImpl : UserManUserPropertyAPI {
	private {
		UserManController m_ctrl;
	}

	this(UserManController ctrl)
	{
		m_ctrl = ctrl;
	}

	final override Json[string] get(User.ID _user)
	{
		return m_ctrl.getUser(_user).properties;
	}

	final override Json get(User.ID _user, string _name)
	{
		auto props = m_ctrl.getUser(_user).properties;
		auto pv = _name in props;
		if (!pv) return Json(null);
		return *pv;
	}

	final override void set(User.ID _user, string _name, Json value)
	{
		m_ctrl.setProperty(_user, _name, value);
	}

	final override void remove(User.ID _user, string _name)
	{
		m_ctrl.removeProperty(_user, _name);
	}
}

private class UserManGroupAPIImpl : UserManGroupAPI {
	private {
		UserManController m_ctrl;
		UserManGroupMemberAPIImpl m_members;
	}

	this(UserManController ctrl)
	{
		m_ctrl = ctrl;
		m_members = new UserManGroupMemberAPIImpl(ctrl);
	}

	Collection!UserManGroupMemberAPI members(string _group) { return Collection!UserManGroupMemberAPI(m_members, _group); }

	@property long count()
	{
		return m_ctrl.getGroupCount();
	}

	void create(string name, string description)
	{
		m_ctrl.addGroup(name, description);
	}

	void remove(string name)
	{
		m_ctrl.removeGroup(name);
	}

	void setDescription(string name, string description)
	{
		m_ctrl.setGroupDescription(name, description);
	}

	/*Group getByID(Group.ID id)
	{
		return m_ctrl.getGroup(id);
	}*/

	Group get(string id)
	{
		return Group(m_ctrl.getGroup(id));
	}

	Group[] getRange(long first_group, long max_count)
	{
		import std.array : appender;
		auto ret = appender!(Group[]);
		m_ctrl.enumerateGroups(first_group, max_count, (ref grp) { ret ~= Group(grp); });
		return ret.data;
	}
}

private class UserManGroupMemberAPIImpl : UserManGroupMemberAPI {
	private {
		UserManController m_ctrl;
	}

	this(UserManController ctrl)
	{
		m_ctrl = ctrl;
	}

	long count(string _group)
	{
		return m_ctrl.getGroupMemberCount(_group);
	}

	User.ID[] getRange(string _group, long first_member, long max_count)
	{
		User.ID[] ret;
		m_ctrl.enumerateGroupMembers(_group, first_member, max_count, (id) { ret ~= id; });
		return ret;
	}

	void add(string _group, User.ID user_id)
	{
		m_ctrl.addGroupMember(_group, user_id);
	}

	void remove(string _group, User.ID _user)
	{
		m_ctrl.removeGroupMember(_group, _user);
	}
}


private {
	UserManAPI m_api;
}
