create table device_relationship (
      device_relationship_id varchar(32) primary key,
      device_id varchar(32),
      owner_id varchar(32),
      app_name varchar(64),
      create_date timestamp without time zone
    );
