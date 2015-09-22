/**
	Local and REST API access.

	Copyright: © 2015 RejectedSoftware e.K.
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
	@property UserManUserAPI users();

	/// Interface suitable for manipulating group information
	@property UserManGroupAPI groups();
}


/// Interface suitable for manipulating user information
interface UserManUserAPI {
	/// Gets the total number of registered users.
	@property long count();

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
	User get(User.ID id);

	/// Gets information about a user using the user name as the identifier.
	User getByName(string q);

	/// Gets information about a user using the e-mail address as the identifier.
	User getByEmail(string q);

	/// Gets information about a user using the user name or e-mail address as the identifier.
	User getByEmailOrName(string q);

	/// Gets information about a range of users, suitable for pagination.
	User[] getRange(int first_user, int max_count);

	/// Deletes a user account.
	void remove(User.ID id);
	//void update(in ref User user);

	/// Updates the e-mail address of a user account.
	void setEmail(User.ID id, string email);

	/// Updates the display name of a user.
	void setFullName(User.ID id, string full_name);

	/// Sets a new password.
	void setPassword(User.ID id, string password);

	/// Sets the activation state of a user.
	void setActive(User.ID id, bool active);

	/// Sets the banned state of a user.
	void setBanned(User.ID id, bool banned);

	/// Sets a custom user account property.
	void setProperty(User.ID id, string name, Json value);

	/// Removes a user account property.
	void removeProperty(User.ID id, string name);
}

/// Interface suitable for manipulating group information
interface UserManGroupAPI {
	/// The total number of groups.
	@property long count();

	/// Creates a new group.
	void create(string name, string description);

	/// Gets information about an existing group.
	//Group getByID(Group.ID id);

	/// Gets information about a group using its name as the identifier.
	Group get(string id);

	/// Gets a range of groups, suitable for pagination.
	Group[] getRange(long first_group, long max_count);

	/// Gets the number of members of a certain group.
	long getMemberCount(string id);

	/// Gets a list of group members, suitable for pagination.
	User.ID[] getMemberRange(string id, long first_member, long max_count);

	/// Adds a user to a group.
	void addMember(string id, User.ID user_id);

	/// Removes a user from a group.
	void removeMember(string id, User.ID user_id);
}

alias Group = userman.db.controller.Group;
alias User = userman.db.controller.User;

private class UserManAPIImpl : UserManAPI {
	private {
		UserManController m_ctrl;
		UserManUserAPIImpl m_users;
		UserManGroupAPIImpl m_groups;
	}

	this(UserManController ctrl)
	{
		m_ctrl = ctrl;
		m_users = new UserManUserAPIImpl(ctrl);
		m_groups = new UserManGroupAPIImpl(ctrl);
	}

	@property UserManUserAPIImpl users() { return m_users; }
	@property UserManGroupAPIImpl groups() { return m_groups; }
}

private class UserManUserAPIImpl : UserManUserAPI {
	private {
		UserManController m_ctrl;
	}

	this(UserManController ctrl)
	{
		m_ctrl = ctrl;
	}

	@property long count()
	{
		return m_ctrl.getUserCount();
	}

	User.ID testLogin(string name, string password)
	{
		auto ret = m_ctrl.testLogin(name, password);
		enforceHTTP(!ret.isNull, HTTPStatus.unauthorized, "Wrong user name or password.");
		return ret;
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
		return m_ctrl.getUser(id);
	}

	User getByName(string q)
	{
		return m_ctrl.getUserByName(q);
	}

	User getByEmail(string q)
	{
		return m_ctrl.getUserByEmail(q);
	}

	User getByEmailOrName(string q)
	{
		return m_ctrl.getUserByEmailOrName(q);
	}

	User[] getRange(int first_user, int max_count)
	{
		User[] ret;
		m_ctrl.enumerateUsers(first_user, max_count, (ref usr) { ret ~= usr; });
		return ret;
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
}

private class UserManGroupAPIImpl : UserManGroupAPI {
	private {
		UserManController m_ctrl;
	}

	this(UserManController ctrl)
	{
		m_ctrl = ctrl;
	}

	@property long count()
	{
		return m_ctrl.getGroupCount();
	}

	void create(string name, string description)
	{
		return m_ctrl.addGroup(name, description);
	}

	/*Group getByID(Group.ID id)
	{
		return m_ctrl.getGroup(id);
	}*/

	Group get(string id)
	{
		return m_ctrl.getGroup(id);
	}

	Group[] getRange(long first_group, long max_count)
	{
		Group[] ret;
		m_ctrl.enumerateGroups(first_group, max_count, (ref grp) { ret ~= grp; });
		return ret;
	}

	void addMember(string id, User.ID user_id)
	{
		m_ctrl.addGroupMember(id, user_id);
	}

	void removeMember(string id, User.ID user_id)
	{
		m_ctrl.removeGroupMember(id, user_id);
	}

	long getMemberCount(string id)
	{
		return m_ctrl.getGroupMemberCount(id);
	}

	User.ID[] getMemberRange(string id, long first_member, long max_count)
	{
		User.ID[] ret;
		m_ctrl.enumerateGroupMembers(id, first_member, max_count, (id) { ret ~= id; });
		return ret;
	}
}


private {
	UserManAPI m_api;
}
