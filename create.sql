-- install required things
create extension hstore;

-- create some consistent things to base our tests around.
create schema alpha;
create schema beta;

create table alpha.red (id serial primary key, ts timestamptz, payload text);
create table alpha.green (one int not null, two int not null, ts timestamptz, payload text, primary key (one, two));
create table alpha.blue (ts timestamptz, payload text);

create table beta.red (id serial primary key, ts timestamptz, payload text);
create table beta.green (one int not null, two int not null, ts timestamptz, payload text, primary key (one, two));
create table beta.blue (ts timestamptz, payload text);

insert into alpha.red (id,ts,payload) values (1,'2000-1-1 1:1:1+0','air');
insert into alpha.red (id,ts,payload) values (2,'2000-2-1 2:2:2+0','earth');

insert into alpha.green (one,two,ts,payload) values (3,4,'2000-3-1 3:3:3+0','water');
insert into alpha.green (one,two,ts,payload) values (5,6,'2000-4-1 4:4:4+0','fire');

insert into alpha.blue (ts,payload) values ('2010-10-10 10:10:10+0','this happened');

CREATE EXTENSION flux;
