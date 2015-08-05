/**
	Local and REST API access.

	Copyright: © 2015 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module userman.api;

import userman.db.controller;

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
	User[] get(int first_user, int max_count);

	/// Gets the total number of registered users.
	long getCount();

	/// Deletes a user account.
	void remove(User.ID id);
	//void update(in ref User user);

	/// Updates the e-mail address of a user account.
	void setEmail(User.ID id, string email);

	/// Updates the display name of a user.
	void setFullName(User.ID id, string full_name);

	/// Sets a new password.
	void setPassword(User.ID id, string password);

	/// Sets a custom user account property.
	void setProperty(User.ID id, string name, string value);
}

/// Interface suitable for manipulating group information
interface UserManGroupAPI {
	/// Creates a new group.
	void create(string name, string description);

	/// Gets information about an existing group.
	Group get(Group.ID id);

	/// Gets information about a group using its name as the identifier.
	Group getByName(string q);
}

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

	User[] get(int first_user, int max_count)
	{
		User[] ret;
		m_ctrl.enumerateUsers(first_user, max_count, (ref usr) { ret ~= usr; });
		return ret;
	}

	long getCount()
	{
		return m_ctrl.getUserCount();
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
	
	void setProperty(User.ID id, string name, string value)
	{
		m_ctrl.setProperty(id, name, value);
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

	void create(string name, string description)
	{
		return m_ctrl.addGroup(name, description);
	}

	Group get(Group.ID id)
	{
		return m_ctrl.getGroup(id);
	}

	Group getByName(string q)
	{
		return m_ctrl.getGroupByName(q);
	}
}

private {
	UserManAPI m_api;
}
