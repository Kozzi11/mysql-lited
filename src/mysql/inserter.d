module mysql.inserter;


import std.array;
import std.meta;
import std.range;
import std.string;
import std.traits;


import mysql.appender;
import mysql.exception;
import mysql.type;

enum OnDuplicate : size_t {
	Ignore,
	Error,
	Replace,
	Update,
	UpdateAll,
}
// //works for single struct objects.
// auto insert(ConnectionType, T) (ref ConnectionType connection, const ref T param,  OnDuplicate action = OnDuplicate.Error) {
// 	auto insert = Inserter!ConnectionType(&connection);
// 	insert.start(action, param);
// 	insert.structRow(param);
// 	insert.flush();
// }

// //works for array of structs.
// auto insert(ConnectionType, T) (ref ConnectionType connection, const T[] param, OnDuplicate action = OnDuplicate.Error) {
// 	assert(param.length > 0);
// 	auto insert = Inserter!ConnectionType(&connection);
// 	insert.start(action, param[0]);
// 	foreach(ref p; param)
// 		insert.structRow(p);
// 	insert.flush();
// }

auto inserter(ConnectionType)(auto ref ConnectionType connection) {
	return Inserter!ConnectionType(connection);
}


auto inserter(ConnectionType, Args...)(auto ref ConnectionType connection, OnDuplicate action, string tableName, Args columns) {
	auto insert = Inserter!ConnectionType(&connection);
	insert.start(action, tableName, columns);
	return insert;
}


auto inserter(ConnectionType, Args...)(auto ref ConnectionType connection, string tableName, Args columns) {
	auto insert = Inserter!ConnectionType(&connection);
	insert.start(OnDuplicate.Error, tableName, columns);
	return insert;
}


private template isSomeStringOrSomeStringArray(T) {
	enum isSomeStringOrSomeStringArray = isSomeString!T || (isArray!T && isSomeString!(ElementType!T));
}


struct Inserter(ConnectionType) {
	@disable this();
	@disable this(this);

	this(ConnectionType* connection) {
		conn_ = connection;
		pending_ = 0;
		flushes_ = 0;
	}

	~this() {
		flush();
	}

	void start(Args...)(string tableName, Args fieldNames) if (Args.length && allSatisfy!(isSomeStringOrSomeStringArray, Args)) {
		start(OnDuplicate.Error, tableName, fieldNames);
	}

// 	// implement in terms of the above
// 	void start(T)(OnDuplicate action, T param)  if(is(T == struct)){
// 		import std.datetime;

// 		static if(getUDAs!(T, TableNameAttribute).length)
// 			auto tableName = getUDAs!(T, TableNameAttribute)[0].name;
// 		 else
// 			 auto tableName = typeid(Unqual!T).name.split('.').array[$-1].toLower;

// 		string [] fieldNames;
// 		foreach(member; __traits(allMembers, Unqual!T)) {
// 			static if(isWritableDataMember!(Unqual!T, member)){
// 				alias MemberType = typeof(__traits(getMember, param, member));
// 				static if(is(Unqual!MemberType == struct) && !is(Unqual!MemberType == Date) && !is(Unqual!MemberType == DateTime) && !is(Unqual!MemberType == SysTime) && !is(Unqual!MemberType == Duration))
// 					continue;//just skip it, or we can generate an error.

// 					static if(getUDAs!(__traits(getMember, param, member), NameAttribute).length)
// 						fieldNames ~= cast(string) getUDAs!(__traits(getMember, param, member), NameAttribute)[0].name;
// 					else
// 						fieldNames ~=  member.toLower;				
// 			}
// 		}

// 		fields_ = fieldNames.length;
// 		import std.stdio;
// 		writefln("field_ %s", fields_);

// 		Appender!(char[]) app;

// 		final switch(action) with (OnDuplicate) {
// 		case Ignore:
// 			app.put("insert ignore into ");
// 			break;
// 		case Replace:
// 			app.put("replace into ");
// 			break;
// 		case UpdateAll:
// 			Appender!(char[]) dupapp;

// 			foreach(size_t i, field; fieldNames) {
// 				dupapp.put('`');
// 				dupapp.put(fieldNames[i]);
// 				dupapp.put("`=values(`");
// 				dupapp.put(fieldNames[i]);
// 				dupapp.put("`)");
			
// 				if (i + 1 != fieldNames.length)
// 					dupapp.put(',');
// 			}
// 			dupUpdate_ = dupapp.data;
// 			goto case Update;
// 		case Update:
// 		case Error:
// 			app.put("insert into ");
// 			break;
// 		}

// 		app.put(tableName);
// 		app.put('(');

// 		foreach(size_t i, field; fieldNames) {
// 			app.put('`');
// 			app.put(fieldNames[i]);
// 			app.put('`');
// 			if (i + 1 != fieldNames.length)
// 				app.put(',');
// 		}

// 		app.put(")values");
// 		start_ = app.data;
// }


	void start(Args...)(OnDuplicate action, string tableName, Args fieldNames) if (Args.length && allSatisfy!(isSomeStringOrSomeStringArray, Args)) {
		auto fieldCount = fieldNames.length;

		foreach (size_t i, Arg; Args) {
			static if (isArray!Arg && !isSomeString!Arg) {
				fieldCount = (fieldCount - 1) + fieldNames[i].length;
			}
		}

		fields_ = fieldCount;

		Appender!(char[]) app;

		final switch(action) with (OnDuplicate) {
		case Ignore:
			app.put("insert ignore into ");
			break;
		case Replace:
			app.put("replace into ");
			break;
		case UpdateAll:
			Appender!(char[]) dupapp;

			foreach(size_t i, Arg; Args) {
				static if (isSomeString!Arg) {
					dupapp.put('`');
					dupapp.put(fieldNames[i]);
					dupapp.put("`=values(`");
					dupapp.put(fieldNames[i]);
					dupapp.put("`)");
				} else {
					auto columns = fieldNames[i];
					foreach (j, name; columns) {
						dupapp.put('`');
						dupapp.put(name);
						dupapp.put("`=values(`");
						dupapp.put(name);
						dupapp.put("`)");
						if (j + 1 != columns.length)
							dupapp.put(',');
					}
				}
				if (i + 1 != Args.length)
					dupapp.put(',');
			}
			dupUpdate_ = dupapp.data;
			goto case Update;
		case Update:
		case Error:
			app.put("insert into ");
			break;
		}

		app.put(tableName);
		app.put('(');

		foreach(size_t i, Arg; Args) {
			fieldsMap_[hashOf(fieldNames[i])] = i;//storing the hash of the fieldName along with its index.

			static if (isSomeString!Arg) {
				app.put('`');
				app.put(fieldNames[i]);
				app.put('`');
			} else {
				auto columns = fieldNames[i];
				foreach (j, name; columns) {
					app.put('`');
					app.put(name);
					app.put('`');
					if (j + 1 != columns.length)
						app.put(',');
				}
			}
			if (i + 1 != Args.length)
				app.put(',');
		}

		app.put(")values");
		start_ = app.data;
	}

	auto ref duplicateUpdate(string update) {
		dupUpdate_ = cast(char[])update;
		return this;
	}

	// void structRow(T)(const ref T param){
	// 	import std.datetime;
	// 	if (start_.empty)
	// 		throw new MySQLErrorException("Inserter must be initialized with a call to start()");
		
	// 	if (!pending_)
	// 		values_.put(cast(char[])start_);

	// 	values_.put(pending_ ? ",(" : "(");
	// 	++pending_;
		
	// 	foreach(i, member; __traits(allMembers, T)) {
	// 		static if(isWritableDataMember!(Unqual!T, member)){
	// 			alias MemberType = typeof(__traits(getMember, param, member));
	// 			static if(is(Unqual!MemberType == struct) && !is(Unqual!MemberType == Date) && !is(Unqual!MemberType == DateTime) && !is(Unqual!MemberType == SysTime) && !is(Unqual!MemberType == Duration))
	// 				continue;//just skip it, or we can generate an error.

	// 				appendValue(values_, __traits(getMember, param, member));
	// 				if (i != fields_)
	// 					values_.put(',');
	// 		}
	// 	}
	// 	values_.put(')');

	// 	if (values_.data.length > (128 << 10)) // todo: make parameter
	// 		flush();

	// 	++rows_;
	// }


	void row(Values...)(Values values) {
		if (start_.empty)
			throw new MySQLErrorException("Inserter must be initialized with a call to start()");

		auto valueCount = values.length;

		foreach (size_t i, Value; Values) {
			static if (isArray!Value && !isSomeString!Value) {
				valueCount = (valueCount - 1) + values[i].length;
			}
		}

		if (valueCount != fields_)
			throw new MySQLErrorException(format("Wrong number of parameters for row. Got %d but expected %d.", valueCount, fields_));

		if (!pending_)
			values_.put(cast(char[])start_);

		values_.put(pending_ ? ",(" : "(");
		++pending_;
		foreach (size_t i, Value; Values) {
			static if (isArray!Value && !isSomeString!Value) {
				appendValues(values_, values[i]);
			} else {
				appendValue(values_, values[i]);
			}
			if (i != values.length-1)
				values_.put(',');
		}
		values_.put(')');

		if (values_.data.length > (128 << 10)) // todo: make parameter
			flush();

		++rows_;
	}

	void row(T)(ref const T param) if(is(T == struct)){
		row(param, getFiledsIndex(param));
	}

	void rows(T)(ref const T[] param) if(is(T == struct)){
		assert (param.length > 0);
		auto indMap = getFiledsIndex(param[0]);
		foreach(ref p; param)
			row(p, indMap);
	}

	private void row(T)(string[] values, ref const T param) {
		if (start_.empty)
			throw new MySQLErrorException("Inserter must be initialized with a call to start()");

		auto valueCount = values.length;

		if (valueCount != fields_)
			throw new MySQLErrorException(format("Wrong number of parameters for row. Got %d but expected %d.", valueCount, fields_));

		if (!pending_)
			values_.put(cast(char[])start_);

		values_.put(pending_ ? ",(" : "(");
		++pending_;
		foreach (size_t i, value; values) {
			
			foreach(member; __traits(allMembers, T)){
				if(member == values[i])
					appendValue(values_, __traits(getMember, param, member));
			}

			if (i != values.length-1)
				values_.put(',');
		}
		values_.put(')');

		if (values_.data.length > (128 << 10)) // todo: make parameter
			flush();

		++rows_;
	}

	private auto getFiledsIndex(T)(ref const T param){
		import mysql.row : unCamelCase;
		import std.algorithm: countUntil;
		import std.stdio;

		string[long] indMap;
		long index = -1;
			foreach(member; __traits(allMembers, T)){//find the index of the respective member for this field.
				index = -1;
				static if(isReadableDataMember!(Unqual!T, member)){
					static if(getUDAs!(__traits(getMember, param, member), NameAttribute).length){//if we have name attribute we should only check it
					auto name = getUDAs!(__traits(getMember, param, member), NameAttribute)[0].name;
						if(auto i = hashOf(name) in fieldsMap_)
							index = *i;
					}
					else {
						static if(getUDAs!(T, UnCamelCaseAttribute).length){//if uncamelcase provided we shoud check both
							if(auto i = hashOf(member) in fieldsMap_)
								index = *i;
							if(auto i = hashOf(member.unCamelCase) in fieldsMap_)
								index = *i;
							}
						else {
							if(auto i = hashOf(member) in fieldsMap_)
								index = *i;
						}
					}
					if(index != -1)
						indMap[index] = member;
					else
						writefln("member %s not specified in the fields list.", member);
				}
			}

		return indMap;
	}


	private void row(T)(ref const T param, ref string[long] indMap) if(is(T == struct)){
		string[] values;
		values.reserve(fields_);
		for(ushort i = 0; i < fields_; i++){
			if(auto index = i in indMap)
				values ~=  *index;
		}
		row(values, param);
	}

	@property size_t rows() const {
		return rows_ != 0;
	}

	@property size_t pending() const {
		return pending_ != 0;
	}

	@property size_t flushes() const {
		return flushes_;
	}

	void flush() {
		if (pending_) {
			if (dupUpdate_.length) {
				values_.put(cast(ubyte[])" on duplicate key update ");
				values_.put(cast(ubyte[])dupUpdate_);
			}

			auto sql = cast(char[])values_.data();
			values_.clear;
			pending_ = 0;

			conn_.execute(sql);
			++flushes_;
		}
	}

private:
	char[] start_;
	char[] dupUpdate_;
	Appender!(char[]) values_;

	ConnectionType* conn_;
	size_t pending_;
	size_t flushes_;
	size_t fields_;
	size_t rows_;
	size_t[size_t] fieldsMap_;
}
