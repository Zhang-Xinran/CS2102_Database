add_course_package: 
This routine is used to add a new course package for sale. 
The inputs to the routine include the following: 
package name, number of free course sessions, start and end date 
indicating the duration that the promotional package is available for sale, 
and the price of the package. 

The course package identifier is generated by the system. 
If the course package information is valid, the routine will perform the necessary updates to add the new course package.

drop procedure add_course_package, buy_course_package;
drop function get_available_course_packages, check_refundable, get_redeemed_session, get_my_available_course_package, get_my_course_package;
drop procedure register_session;
drop function get_my_registrations, update_course_session;
drop function top_packages;


create or replace procedure add_course_package 
	(package_name text, num_of_free_sessions integer, start_date date, end_date date, price decimal(5, 2))
as $$
begin
insert into Course_packages (name, sale_start_date, sale_end_date, num_free_registration, price)
	values (package_name, start_date, end_date, num_of_free_sessions, price);
end;
$$ language plpgsql;

-- Constraints: sale_end_date > sale_start_date


The routine returns a table of records with the following information for each available course package: package name, number of free course sessions, end date for promotional package, and the price of the package.

create or replace function get_available_course_packages()
returns table (id int, name text, num_free_registration int, sale_end_date date, price decimal(5, 2)) as $$
select C.package_id, C.name, C.num_free_registration, C.sale_end_date, C.price
from Course_packages C
where sale_end_date >= (select current_date);
$$ language sql;

buy_course_package: This routine is used when a customer requests to purchase a course package. 
The inputs to the routine include the customer and course package identifiers. 
If the purchase transaction is valid, the routine will process the purchase with the necessary updates (e.g., payment).
create or replace procedure buy_course_package 
	(cid integer, pid integer)
as $$
declare 
	buy_date date;
	card text;
	num_free_registration int;
begin
	buy_date := (select current_date);
	card := (select card_number from Owns C where C.cust_id = cid);
	num_free_registration := (select CP.num_free_registration from Course_packages CP where CP.package_id = pid);
	insert into Buys (buy_date, package_id, card_number, cust_id, num_remaining_redemptions) 
		values (buy_date, pid, card, cid, num_free_registration);
end;
$$ language plpgsql;

This routine is used when a customer requests to view his/her active/partially active course package. 
The input to the routine is a customer identifier. 

The routine returns the following information as a JSON value: 
package name, 
purchase date, 
price of package, 
number of free sessions included in the package, 
number of sessions that have not been redeemed, 
and information for each redeemed session (course name, session date, session start hour). 

The redeemed session information is sorted in ascending order of session date and start hour.

A customer’s course package is classified as either active if there is at least one unused session in the package, 
partially active if all the sessions in the package have been redeemed 
but there is at least one redeemed session that could be refunded if it is cancelled, or inactive otherwise. 
Each customer can have at most one active or partially active package.

create or replace function check_refundable
	(in buy_d date, in cid int, in card text, in pid int, out res int)
returns integer as $$
declare
	curs cursor for (select * from Redeems R where R.buy_date = buy_d and R.cust_id = cid and R.card_number = card and R.pid = package_id);
	r record;
begin
	res := 1;
	open curs;
	loop
		fetch curs into r;
		exit when not found;
		if ((select current_date) - (select session_date from Sessons S where S.sid = r.sid and S.offering_id = r.offering_id) < 7) then
			res := 0; 
		end if;
	end loop;
end;	
$$ language plpgsql;

create or replace function get_redeemed_session
	(in buy_d date, in cid int, in card text, in pid int, out res json[])
returns json[] as $$
declare
	cur cursor for (select * from Redeems R where R.buy_date = buy_d and R.cust_id = cid and R.card_number = card and R.package_id = pid);
	r record;
	temp json;
	session_name text;
	session_date date;
	session_start_hour int;
begin
	open cur;
	loop
		fetch cur into r;
		exit when not found;
		session_name := (select title from Courses where course_id = (select course_id from Offerings O where O.offering_id = r.offering_id));
		session_date := (select session_date from Sessions S where S.sid = r.sid and S.offering_id = r.offering_id);
		session_start_hour := (select start_time from Session S where S.sid = r.sid and S.offering_id = r.offering_id);
		temp := json_build_object(
			'session_name', session_name,
			'session_dates', session_date,
			'session_start_hour', session_start_hour
		);
		res := array_append(res, temp);
	end loop;
	close cur;
end;
$$ language plpgsql;

create or replace function get_my_available_course_package
	(in cid int, out res record)
returns record as $$
declare
	curs cursor for (select * from Buys where cust_id = cid);
	r record;
begin
	open curs;
	loop
		fetch curs into r;
		if (r.num_remaining_redemptions > 0 or 
			(select check_refundable(r.buy_date, r.cust_id, r.card_number, r.package_id)) = 1) then
			res := r;
		end if;
	end loop;
	close curs;
end;
$$ language plpgsql;

create or replace function get_my_course_package 
	(in cid int, out res json)
returns json as $$
declare
	name text;
	purchase_date date;
	package_price decimal(5, 2);
	num_free_sessions int;
	num_available_sessions int;
	curs cursor for (select * from Buys where cust_id = cid);
	r record;
	redeemed_sessions json[];
begin
	open curs;
	loop
		fetch curs into r;
		exit when not found;
		if (r.num_remaining_redemptions > 0 or 
			(select check_refundable(r.buy_date, r.cust_id, r.card_number, r.package_id)) = 1) then
			name := (select CP.name from Course_packages CP where CP.package_id = r.package_id);
			purchase_date := r.buy_date;
			package_price := (select price from Course_packages CP where CP.package_id = r.package_id);
			num_free_sessions := (select num_free_registration from Course_packages CP where CP.package_id = r.package_id);
			num_available_sessions := r.num_remaining_redemptions; 
			redeemed_sessions := (select get_redeemed_session(r.buy_date, r.cust_id, r.card_number, r.package_id));
			res := json_build_object(
				'package_name', name, 
				'purchase_date', purchase_date, 
				'package_price', package_price,
				'num_free_sessions', num_free_sessions,
				'num_available_sessions', num_available_sessions,
				'redeemed_sessions', redeemed_sessions
			);

		end if;
	end loop;
	close curs;

end;
$$ language plpgsql;


register_session: 
This routine is used when a customer requests to register for a session in a course offering. 
The inputs to the routine include the following: 
customer identifier, course offering identifier, session number, and payment method (credit card or redemption from active package). 
If the registration transaction is valid, 
this routine will process the registration with the necessary updates (e.g., payment/redemption).

-- 1 will represent via credit card
-- 2 will represent via redemption
create or replace procedure register_session
	(cid int, coid int, sid int, paymentMethod int)
as $$
declare
	redeemed_package record;
begin
	if (paymentMethod = 1) then
		insert into Registers
			values ((select current_date),
				(select card_number from Owns where cust_id = cid),
				cid, sid, coid);
	else
		redeemed_package := get_my_available_course_package();
		insert into Redeems
			values ((select current_date),
				redeemed_package.buy_date,
				redeemed_package.package_id,
				redeemed_package.card_number,
				redeemed_package.cust_id,
				sid, coid);
		update Buys
		 	num_remaining_redemptions = num_remaining_redemptions - 1
			where buy_date = redeemed_package.buy_date and 
				package_id = redeemed_package.package_id and
				card_number = redeemed_package.card_number and
				cust_id = redeemed_package.cust_id;
	end if;
end;
$$ language plpgsql;



get_my_registrations: 
This routine is used when a customer requests to view his/her active course registrations 
(i.e, registrations for course sessions that have not ended). 
The input to the routine is a customer identifier. 
The routine returns a table of records with the following information for each active registration session: 
course name, course fees, session date, session start hour, session duration, and instructor name. 
The output is sorted in ascending order of session date and session start hour.

create or replace function get_my_registered_sessions
	(in cid int)
returns table (cname text, cfee decimal(5, 2), sdate date, start_hour integer, duration integer, instructor text) as $$
declare
	curs_registers cursor for (select * from Registers where cust_id = cid);
	curs_redeems cursor for (select * from Redeems where cust_id = cid);
	r record;
	deadline date;
begin
	open curs_registers;
	loop
		fetch curs_registers into r;
		exit when not found;
		deadline := (select registration_deadline from Offerings O where O.offering_id = r.offering_id);
		if (deadline >= (select current_date)) then
			cname := (select title from Courses C where C.course_id = (select course_id from Offerings O where O.offering_id = r.offering_id));
			cfee := (select fees from Offerings O where O.offering_id = r.offering_id);
			sdate := (select session_date from Sessions S where S.offering_id = r.offering_id and S.sid = r.sid);
			start_hour := (select start_time from Sessons S where S.offering_id = r.offering_id and S.sid = r.sid);
			duration := (select end_time from Sessons S where S.offering_id = r.offering_id and S.sid = r.sid) - r.start_hour;
			instructor := (select name from Employees E where E.eid = (select eid from Sessions S where S.offering_id = r.offering_id and S.sid = r.sid));
			return next;
		end if;
	end loop;
	close curs_registers;
	open curs_redeems;
	loop
		fetch curs_redeems into r;
		exit when not found;
		deadline := (select registration_deadline from Offerings O where O.offering_id = r.offering_id);
		if (deadline >= (select current_date)) then
			cname := (select title from Courses C where C.course_id = (select course_id from Offerings O where O.offering_id = r.offering_id));
			cfee := (select fees from Offerings O where O.offering_id = r.offering_id);
			sdate := (select session_date from Sessions S where S.offering_id = r.offering_id and S.sid = r.sid);
			start_hour := (select start_time from Sessons S where S.offering_id = r.offering_id and S.sid = r.sid);
			duration := (select end_time from Sessons S where S.offering_id = r.offering_id and S.sid = r.sid) - r.start_hour;
			instructor := (select name from Employees E where E.eid = (select eid from Sessions S where S.offering_id = r.offering_id and S.sid = r.sid));
			return next;
		end if;
	end loop;
	close curs_redeems;
end; 
$$ language plpgsql;

create or replace function get_my_registrations
	(in cid int)
returns table (course_name text, course_fee decimal(5, 2), 
	session_date date, start_hour integer, duration integer, instructor text) as $$
begin
	return query select * 
	from (select get_my_registered_sessions(cid)) as T
	order by (sdate, start_hour) asc;
end;
$$ language plpgsql;


update_course_session: 
This routine is used when a customer requests to change a registered course session to another session. 
The inputs to the routine include the following: 
customer identifier, course offering identifier, and new session number. 
If the update request is valid and there is an available seat in the new session, 
the routine will process the request with the necessary updates.
create or replace function get_payment_type
	(in cid int, in coid int, out payment_type int)
as $$
begin
	if (select count() from Registers where cid = cust_id and coid = offering_id) = 1 then
		payment_type = 1;
	else
		payment_type = 2;
	end if;
end;
$$ language plpgsql;

create or replace procedure update_course_session
	(cid int, coid int, new_sid int)
as $$
	if (select get_payment_type()) = 1 then
	-- update Registers
		update Registers
			set sid = new_sid
			where cust_id = cid and coid = offering_id;
	else
	-- update Redeems
		update Redeems
			set sid = new_sid
			where cust_id = cid and coid = offering_id;
	end if;

$$ language plpgsql;

top_packages: 
This routine is used to find the top N course packages in terms of the total number of packages sold for this year 
(i.e., the package’s start date is within this year). The input to the routine is a positive integer number N. 
The routine returns a table of records consisting of the following information for each of the top N course packages: 
package identifier, number of included free course sessions, price of package, start date, end date, and number of packages sold. 
The output is sorted in descending order of number of packages sold followed by descending order of price of package. 
In the event that there are multiple packages that tie for the top Nth position, 
all these packages should be included in the output records; thus, the output table could have more than N records. 
It is also possible for the output table to have fewer than N records if N is larger than the number of packages launched this year.

create or replace function top_packages


-- Trigger Part
-- // editn Course_packages num_free_registration >= 0
-- // register 要有trigger控制registration人数小于seating
-- // 一个人只能有一个course package


drop function limit_session_quota;
drop trigger limit_session_in_registers on Registers;
drop trigger limit_session_in_redeems on Redeems;

create or replace function limit_session_quota()
returns trigger as $$
declare
	num_of_registrations int;
	num_of_redemptions int;
	num_of_capacity int;
begin
	num_of_registrations := (select count(*) from Registers R where new.offering_id = R.offering_id and new.sid = R.sid);
	num_of_redemptions := (select count(*) from Redeems R where new.offering_id = R.offering_id and new.sid = R.sid);
	num_of_capacity := (select seating_capacity from Rooms R where R.rid = (select rid from Sessions S where new.offering_id = S.offering_id and new.sid = S.sid ));
	if (num_of_capacity > num_of_registrations + num_of_redemptions) then
		return new;
	else
		return null;
	end if;
end;
$$ language plpgsql;

create trigger limit_session_in_registers
before insert or update on Registers
for each row execute function limit_session_quota();

create trigger limit_session_in_redeems
before insert or update on Redeems
for each row execute function limit_session_quota();

create or replace trigger 