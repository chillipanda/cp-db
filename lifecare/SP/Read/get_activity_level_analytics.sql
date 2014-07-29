  -- Drop function
  DO $$
  DECLARE fname text;
  BEGIN
  FOR fname IN SELECT oid::regprocedure FROM pg_catalog.pg_proc WHERE proname = 'get_activity_level_analytics' LOOP
    EXECUTE 'DROP FUNCTION ' || fname;
  END loop;
  RAISE INFO 'FUNCTION % DROPPED', fname;
  END$$;
  -- Start function
  CREATE FUNCTION get_activity_level_analytics(
          pDeviceId varchar(32)
          , pDay date
      )
  RETURNS TABLE(
      -- activity_level integer
      eyecare_id varchar(32)
      , prev_row_create_date timestamp without time zone
      , next_row_create_date timestamp without time zone
      , duration_apart integer
      , event_type_id varchar(64)
      , event_type_name varchar(64)
      , node_name varchar(64)
      , zone varchar(64)
      , create_date timestamp without time zone
      , extra_data varchar(64)
      , wakeup_time timestamp without time zone
      , sleeping_time timestamp without time zone
      , sleeping_time_hour integer
      , day_duration integer
      , night_duration integer
      , day_away_duration integer
      , night_away_duration integer
      , day_active integer
      , night_active integer
      , day_activity_level float
      , night_activity_level float
    )
  AS
  $BODY$
  DECLARE
    pWakeupTime timestamp without time zone default null;
    pSleepingTime timestamp without time zone default null;

    pDayDuration integer;
    pNightDuration integer;
    pDayAwayDuration integer;
    pNightAwayDuration integer;
    pDayAwayDurationTemp integer;
    pNightAwayDurationTemp integer;

    pNightStart timestamp without time zone;
    pNightEnd timestamp without time zone;
    pNight2Start timestamp without time zone;
    pNight2End timestamp without time zone;

    pDayOverlaps boolean default false;
    pNightOverlaps boolean default false;

    pDayStart timestamp without time zone;
    pDayEnd timestamp without time zone;
    pDay2Start timestamp without time zone;
    pDay2End timestamp without time zone;

    pDayActivityLevel float;
    pNightActivityLevel float;

    nRow record;
    dRow record;
    aRow record;

    awayRowCount integer;
    lastUserEventTypeId varchar(64);
    lastUserExtraData varchar(64);

    dTempDuration integer;
    nTempDuration integer;

    dActive integer;
    nActive integer;
  BEGIN
      -- get the wake up time
      SELECT
        (pDay || 'T' || EXTRACT (HOUR FROM  date_value2) || ':' || EXTRACT (MINUTE FROM date_value2))::timestamp
      INTO
        pWakeupTime
      FROM analytics_value
      WHERE
        type = 'W' AND
        date_value = (pDay || 'T' || '00:00')::timestamp AND
        owner_id = pDeviceId;

      -- get the sleep time
      SELECT
        (pDay || 'T' || EXTRACT (HOUR FROM  date_value2) || ':' || EXTRACT (MINUTE FROM date_value2))::timestamp
      INTO
        pSleepingTime
      FROM analytics_value
      WHERE
        type = 'S' AND
        date_value = (pDay || 'T' || '00:00')::timestamp AND
        owner_id = pDeviceId;


      -- if there are not sleep time or wake up time, user might be away. get the median wake up time and median sleeping time
      IF pWakeupTime IS NULL THEN
        SELECT
          (pDay || 'T' || EXTRACT (HOUR FROM  date_value2) || ':' || EXTRACT (MINUTE FROM date_value2))::timestamp
        INTO
          pWakeupTime
        FROM informative_analytics
        WHERE
          type = 'MW' AND
          date_value2 IS NOT NULL
        ORDER BY date_value DESC;
      END IF;

      IF pSleepingTime IS NULL THEN
        SELECT
          (pDay || 'T' || EXTRACT (HOUR FROM date_value2) || ':' || EXTRACT (MINUTE FROM date_value2))::timestamp
        INTO
          pSleepingTime
        FROM informative_analytics
        WHERE
          type = 'MS' AND
          date_value2 IS NOT NULL
        ORDER BY date_value DESC;
      END IF;

      -- if there are still no sleep time or wake up time, we use the core analytics value
      IF pWakeupTime IS NULL THEN
        SELECT
          (pDay || 'T' || EXTRACT (HOUR FROM date_value) || ':' || EXTRACT (MINUTE FROM date_value))::timestamp
        INTO
          pWakeupTime
        FROM core_analytics
        WHERE
          type = 'MW';
      END IF;

      IF pSleepingTime IS NULL THEN
        SELECT
          (pDay || 'T' || EXTRACT (HOUR FROM date_value) || ':' || EXTRACT (MINUTE FROM date_value))::timestamp
        INTO
          pSleepingTime
        FROM core_analytics
        WHERE
          type = 'MS';
      END IF;

      IF EXTRACT (HOUR FROM pSleepingTime)::integer < 12 THEN
        pDayOverlaps = true;
      ELSEIF EXTRACT (HOUR FROM pSleepingTime)::integer > 12 THEN
        pNightOverlaps = true;
      END IF;

      IF pWakeupTime IS NOT NULL AND pSleepingTime IS NOT NULL THEN
        -- get all the day activities
        CREATE TEMP TABLE day_activities_temp AS
          SELECT
            e.eyecare_id
            , lag(e.create_date)  over (ORDER BY e.eyecare_id) AS prev_row_create_date
            , lead(e.create_date)  over (ORDER BY e.eyecare_id) AS next_row_create_date
            , EXTRACT (EPOCH FROM ((lead(e.create_date) over (ORDER BY e.eyecare_id)) - e.create_date))::integer AS duration_apart
            , e.event_type_id
            , e.event_type_name
            , e.node_name
            , e.zone
            , e.create_date
            , e.extra_data
          FROM eyecare e
          WHERE
            (
              (pDayOverlaps = true AND e.create_date BETWEEN pWakeupTime AND (pDay || 'T' || '23:59')::timestamp) OR -- day activities which sleeping time that crosses the 12 am line
              (pDayOverlaps = true AND e.create_date BETWEEN (pDay || 'T' || '00:00')::timestamp AND pSleepingTime) OR -- day activities which sleeping time that crosses the 12 am line
              (pNightOverlaps = true AND e.create_date BETWEEN pWakeupTime AND pSleepingTime) -- normal day activities
            )
          AND ((pDeviceId = NULL) OR (e.device_id = pDeviceId))  AND (
                (e.node_name IN ('Door sensor', 'door sensor')  AND e.event_type_id = '20001' AND e.extra_data IN ('Alarm On', 'Alarm Off')) OR -- door sensor alarm report on door open "Alarm On"
                (e.event_type_id IN ('20002', '20003', '20004') AND e.zone = 'Master Bedroom') OR -- Bedroom motion sensor alarm on
                (e.event_type_id IN ('20002', '20003', '20004') AND e.zone = 'Kitchen') OR -- Kitchen  motion sensor alarm on
                (e.event_type_id IN ('20002', '20003', '20005') AND e.zone = 'Bathroom') OR -- Get only the sensor off in the bathroom
               (e.event_type_id IN ('20013')) -- Get BP HR Reading
             )
          ORDER BY eyecare_id;

          -- get the day length
          IF (pDayOverlaps = true) THEN
            pDayDuration = (EXTRACT (EPOCH FROM (((pDay || 'T' || '23:59')::timestamp - pWakeupTime) + (pSleepingTime - (pDay || 'T' || '00:00')::timestamp))))::integer;
          ELSEIF (pNightOverlaps = true) THEN
            pDayDuration = (EXTRACT (EPOCH FROM (pSleepingTime - pWakeupTime)))::integer;
          END IF;

          -- get all the night activities
          CREATE TEMP TABLE night_activities_temp AS
            SELECT
              e.eyecare_id
              , lag(e.create_date) over (ORDER BY e.eyecare_id) AS prev_row_create_date
              , lead(e.create_date) over (ORDER BY e.eyecare_id) AS next_row_create_date
              , EXTRACT (EPOCH FROM ((lead(e.create_date) over (ORDER BY e.eyecare_id)) - e.create_date))::integer AS duration_apart
              , e.event_type_id
              , e.event_type_name
              , e.node_name
              , e.zone
              , e.create_date
              , e.extra_data
            FROM eyecare e
            WHERE
              (
                (pDayOverlaps = true AND e.create_date BETWEEN pSleepingTime AND pWakeupTime) OR -- night activities which sleeping time that crosses the 12 am line
                (pNightOverlaps = true AND e.create_date BETWEEN pSleepingTime AND (pDay || 'T' || '23:59')::timestamp) OR -- normal night activities before 12am
                (pNightOverlaps = true AND e.create_date BETWEEN (pDay || 'T' || '00:00')::timestamp AND pWakeupTime) -- night activities after 12am
              )
            AND ((pDeviceId = NULL) OR (e.device_id = pDeviceId))  AND (
                  (e.node_name IN ('Door sensor', 'door sensor')  AND e.event_type_id = '20001' AND e.extra_data IN ('Alarm On', 'Alarm Off')) OR -- door sensor alarm report on door open "Alarm On"
                  (e.event_type_id IN ('20002', '20003', '20004') AND e.zone = 'Master Bedroom') OR -- Bedroom motion sensor alarm on
                  (e.event_type_id IN ('20002', '20003', '20004') AND e.zone = 'Kitchen') OR -- Kitchen  motion sensor alarm on
                  (e.event_type_id IN ('20002', '20003', '20005') AND e.zone = 'Bathroom') OR -- Get only the sensor off in the bathroom
                 (e.event_type_id IN ('20013')) -- Get BP HR Reading
               )
            ORDER BY eyecare_id;


          -- get the night length
          IF (pNightOverlaps = true) THEN
            pNightDuration = (EXTRACT (EPOCH FROM (((pDay || 'T' || '23:59')::timestamp - pSleepingTime) + (pWakeupTime - (pDay || 'T' || '00:00')::timestamp))))::integer;
          ELSEIF (pDayOverlaps = true ) THEN
            pNightDuration = (EXTRACT (EPOCH FROM (pWakeupTime - pSleepingTime)))::integer;
          END IF;


          -- Find the total activity for the day
          dTempDuration = 0;
          dActive = 0;
          -- For each of the day duration's row get the duration calculation
          FOR dRow IN SELECT * from day_activities_temp LOOP
            IF dRow.duration_apart IS NOT NULL AND dRow.duration_apart < 300 THEN
              dTempDuration = dTempDuration + dRow.duration_apart; -- add on to the temp stack if elderly is active within 5 minutes of motion detect
            ELSE
              dTempDuration = dTempDuration + 300; -- add 5 minutes to the temp stack for last motion detected
              dActive = dActive + dTempDuration; -- add the temp stack to the total activity level
              dTempDuration = 0; -- clear the temp stack
            END IF;
          END LOOP;

          -- Find the total activity for the night
          nTempDuration = 0;
          nActive = 0;
          -- For each of the day duration's row get the duration calculation
          FOR nRow IN SELECT * from night_activities_temp LOOP
            IF nRow.duration_apart IS NOT NULL AND nRow.duration_apart < 300 THEN
              nTempDuration = nTempDuration + nRow.duration_apart; -- add on to the temp stack if elderly is active within 5 minutes of motion detect
            ELSE
              nTempDuration = nTempDuration + 300; -- add 5 minutes to the temp stack for last motion detected
              nActive = nActive + nTempDuration; -- add the temp stack to the total activity level
              nTempDuration = 0; -- clear the temp stack
            END IF;
          END LOOP;

          -- Get the total away duration
          CREATE TEMP TABLE away_values_temp AS
              SELECT * FROM get_away_analytics(pDeviceId, pDay);

          SELECT COUNT(*) INTO awayRowCount FROM away_values_temp;

          pDayAwayDuration = 0;
          pNightAwayDuration = 0;

          IF awayRowCount > 0 THEN
            -- get the duration of each outing
            FOR aRow IN SELECT * FROM away_values_temp LOOP

              -- Get the intervals for the night
              IF (pNightOverlaps = true) THEN
                pNightStart = pSleepingTime;
                pNightEnd = (pDay || 'T' || '23:59')::timestamp;
                pNight2Start = (pDay || 'T' || '00:00')::timestamp;
                pNight2End = pWakeupTime;

                pDayStart = pWakeupTime;
                pDayEnd = pSleepingTime;

              ELSEIF (pDayOverlaps = true) THEN

                pDayStart = pWakeupTime;
                pDayEnd = (pDay || 'T' || '23:59')::timestamp;
                pDay2Start = (pDay || 'T' || '00:00')::timestamp;
                pDay2End = pSleepingTime;

                pNightStart = pSleepingTime;
                pNightEnd = pWakeupTime;

              ELSE
                pDayStart = pWakeupTime;
                pDayEnd = pSleepingTime;

                pNightStart = pSleepingTime;
                pNightEnd = pWakeupTime;
              END IF;

              pDayAwayDurationTemp = 0; -- reset temp storage of away mode;
              pNightAwayDurationTemp = 0; -- reset temp storage of away mode;

              -- Get the away duration for the night and day
              -- 3 scenarios for the time, day overlaps, night overlaps and normal
                CASE
                    -- SCENARIO 1 - Day Overlaps
                    WHEN (pDayOverlaps = true) AND (aRow.away_start BETWEEN pDayStart AND pDayEnd) AND (aRow.away_end BETWEEN pDayStart AND pDayEnd) THEN
                        -- day overlap, goes out and return home during the standard day time
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - aRow.away_start)))::integer;
                    WHEN (pDayOverlaps = true) AND (aRow.away_start BETWEEN pDay2Start AND pDay2End) AND (aRow.away_end BETWEEN pDay2Start AND pDay2End) THEN
                        -- day overlap, goes out and return home during the overlapped day time
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - aRow.away_start)))::integer;
                    WHEN (pDayOverlaps = true) AND (aRow.away_start BETWEEN pNightStart AND pNightEnd) AND (aRow.away_end BETWEEN pNightStart AND pNightEnd) THEN
                        -- day overlap, goes out and return home during the standard night time
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - aRow.away_start)))::integer;
                    WHEN (pDayOverlaps = true) AND (aRow.away_start BETWEEN pDay2Start AND pDay2End) AND (aRow.away_end BETWEEN pDayStart AND pDayEnd) THEN
                        -- day overlap, goes out on the overlapped day time (late night after 12) and return homes during the standard day time
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (pNightStart - aRow.away_start)))::integer + (EXTRACT (EPOCH FROM (aRow.away_end - pNightEnd)))::integer;
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - aRow.away_start)))::integer;
                    WHEN (pDayOverlaps = true) AND (aRow.away_start BETWEEN pDay2Start AND pDay2End) AND (aRow.away_end BETWEEN pNightStart AND pNightEnd) THEN
                        -- day overlap, goes out on the overlapped day time (late night after 12) and return homes during the standard night time
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (pNightStart - aRow.away_start)))::integer;
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - pNightStart)))::integer;
                    WHEN (pDayOverlaps = true) AND (aRow.away_start BETWEEN pNightStart AND pNightEnd) AND (aRow.away_end BETWEEN pDayStart AND pDayEnd) THEN
                        -- day overlap, goes out during the night time and return homes during the standard day time
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (pNightEnd - aRow.away_start)))::integer;
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - pNightEnd)))::integer;
                    WHEN (pDayOverlaps = true) AND (aRow.away_start IS NULL) AND (aRow.away_end BETWEEN pDay2Start AND pDay2End) THEN
                        -- day overlap, return home early in the morning after going out for the whole day
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - (pDay || 'T' || '00:00')::timestamp)))::integer;
                    WHEN (pDayOverlaps = true) AND (aRow.away_start IS NULL) AND (aRow.away_end BETWEEN pNightStart AND pNightEnd) THEN
                        -- day overlap, return home during the night time after going out for the whole day
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (pNightStart - (pDay || 'T' || '00:00')::timestamp)))::integer;
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - pNightStart)))::integer;
                    WHEN (pDayOverlaps = true) AND (aRow.away_start IS NULL) AND (aRow.away_end BETWEEN pDayStart AND pDayEnd) THEN
                        -- day overlap, return home during the standard day time after going out for the whole day
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (pNightStart - (pDay || 'T' || '00:00')::timestamp)))::integer + (EXTRACT (EPOCH FROM (aRow.away_end - pDayStart)))::integer;
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (pNightEnd - pNightStart)))::integer;
                    WHEN (pDayOverlaps = true) AND (aRow.away_end IS NULL) AND (aRow.away_start BETWEEN pDay2Start AND pDay2End) THEN
                        -- day overlap, goes out during the overlapped day time and never return
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (pDayEnd - pDayStart)))::integer;
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (pDayStart - aRow.away_start)))::integer + (EXTRACT (EPOCH FROM ((pDay || 'T' || '23:59')::timestamp - pDayEnd)))::integer;
                    WHEN (pDayOverlaps = true) AND (aRow.away_end IS NULL) AND (aRow.away_start BETWEEN pDayStart AND pDayEnd) THEN
                        -- day overlap, goes out during the day time and never return
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM ((pDay || 'T' || '23:59')::timestamp - aRow.away_start)))::integer;
                    WHEN (pDayOverlaps = true) AND (aRow.away_end IS NULL) AND (aRow.away_end BETWEEN pNightStart AND pNightEnd) THEN
                        -- day overlap, goes out during the night time and never return
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM ((pDay || 'T' || '23:59')::timestamp - pDayStart)))::integer;
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (pDayEnd - aRow.away_start)))::integer;

                    -- SCENARIO 2 - Night Overlaps
                    WHEN (pNightOverlaps = true) AND (aRow.away_start BETWEEN pDayStart AND pDayEnd) AND (aRow.away_end BETWEEN pDayStart AND pDayEnd) THEN
                        -- night overlap, goes out and return home during the standard day time
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - aRow.away_start)))::integer;
                    WHEN (pNightOverlaps = true) AND (aRow.away_start BETWEEN pNightStart AND pNightEnd) AND (aRow.away_end BETWEEN pNightStart AND pNightEnd) THEN
                        -- night overlap, goes out and return home during the standard night time
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - aRow.away_start)))::integer;
                    WHEN (pNightOverlaps = true) AND (aRow.away_start BETWEEN pNight2Start AND pNight2End) AND (aRow.away_end BETWEEN pNight2Start AND pNight2End) THEN
                        -- night overlap, goes out and return home during the overlapped night time
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - aRow.away_start)))::integer;
                    WHEN (pNightOverlaps = true) AND (aRow.away_start BETWEEN pNightStart AND pNightEnd) AND (aRow.away_end BETWEEN pDayStart AND pDayEnd) THEN
                        -- night overlap, goes out during the night time and return home during the day time
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (pNightEnd - aRow.away_start)))::integer;
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - pNightEnd)))::integer;
                    WHEN (pNightOverlaps = true) AND (aRow.away_start BETWEEN pNightStart AND pNightEnd) AND (aRow.away_end BETWEEN pDayStart AND pDayEnd) THEN
                        -- night overlap, goes out during the night time and return home during the overlapped night time
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (pNightEnd - aRow.away_start)))::integer + (EXTRACT (EPOCH FROM (aRow.away_end - pNight2Start)))::integer;
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (pDayEnd - pDayStart)))::integer;
                    WHEN (pNightOverlaps = true) AND (aRow.away_start BETWEEN pDayStart AND pDayEnd) AND (aRow.away_end BETWEEN pNight2Start AND pNight2End) THEN
                        -- night overlap, goes out during the day time and return home during the overlapped night time
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - pDayEnd)))::integer;
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (pDayEnd - aRow.away_start)))::integer;
                    WHEN (pNightOverlaps = true) AND (aRow.away_start IS NULL) AND (aRow.away_end BETWEEN pNightStart AND pNightEnd) THEN
                        -- night overlap, return home during the standard night time after going out for the whole day
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - (pDay || 'T' || '00:00')::timestamp)))::integer;
                    WHEN (pNightOverlaps = true) AND (aRow.away_start IS NULL) AND (aRow.away_end BETWEEN pDayStart AND pDayEnd) THEN
                        -- night overlap, return home during the standard day time after going out for the whole day
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - pDayStart)))::integer;
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (pDayStart - (pDay || 'T' || '00:00')::timestamp)))::integer;
                    WHEN (pNightOverlaps = true) AND (aRow.away_start IS NULL) AND (aRow.away_end BETWEEN pNight2Start AND pNight2End) THEN
                        -- night overlap, return home during the overlapped night time after going out for the whole day
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (pDayEnd - pDayStart)))::integer;
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (pDayStart - (pDay || 'T' || '00:00')::timestamp)))::integer + (EXTRACT (EPOCH FROM (aRow.away_end - pDayEnd)))::integer;
                    WHEN (pNightOverlaps = true) AND (aRow.away_end IS NULL) AND (aRow.away_start BETWEEN pNightStart AND pNightEnd) THEN
                        -- night overlap, goes out during the night time and never return
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (pDayEnd - pDayStart)))::integer;
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (pDayStart - aRow.away_start)))::integer + (EXTRACT (EPOCH FROM ((pDay || 'T' || '23:59')::timestamp - pDayEnd)))::integer;
                    WHEN (pNightOverlaps = true) AND (aRow.away_end IS NULL) AND (aRow.away_start BETWEEN pDayStart AND pDayEnd) THEN
                        -- night overlap, goes out during the day time and never return
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (pDayEnd - aRow.away_start)))::integer;
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM ((pDay || 'T' || '23:59')::timestamp - pDayEnd)))::integer;
                    WHEN (pNightOverlaps = true) AND (aRow.away_end IS NULL) AND (aRow.away_start BETWEEN pNight2Start AND pNight2End) THEN
                        -- night overlap, goes out during the second night time and never return
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM ((pDay || 'T' || '23:59')::timestamp - aRow.away_start)))::integer;

                    -- SCENARIO 3 - No overlappings
                    WHEN (pNightOverlaps = false AND pDayOverlaps = false) AND (aRow.away_start BETWEEN pDayStart AND pDayEnd) AND (aRow.away_end BETWEEN pDayStart AND pDayEnd) THEN
                        -- does no overlap, goes out and return during the standard day time
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - aRow.away_start)))::integer;
                    WHEN (pNightOverlaps = false AND pDayOverlaps = false) AND (aRow.away_start BETWEEN pNightStart AND pNightEnd) AND (aRow.away_end BETWEEN pNightStart AND pNightEnd) THEN
                        -- does no overlap, goes out and return during the standard day time
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - aRow.away_start)))::integer;
                    WHEN (pNightOverlaps = false AND pDayOverlaps = false) AND (aRow.away_start BETWEEN pNightStart AND pNightEnd) AND (aRow.away_end BETWEEN pDayStart AND pDayEnd) THEN
                        -- does no overlap, goes out during the night time and return home during the day time
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (pDayStart - aRow.away_start)))::integer;
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - pDayStart)))::integer;
                    WHEN (pNightOverlaps = false AND pDayOverlaps = false) AND (aRow.away_start IS NULL) AND (aRow.away_end BETWEEN pNightStart AND pNightEnd) THEN
                        -- does no overlap, return home during the night time after going out for the whole day
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - (pDay || 'T' || '00:00')::timestamp)))::integer;
                    WHEN (pNightOverlaps = false AND pDayOverlaps = false) AND (aRow.away_start IS NULL) AND (aRow.away_end BETWEEN pDayStart AND pDayEnd) THEN
                        -- does no overlap, return home during the day time after going out for the whole day
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (pDayStart - (pDay || 'T' || '00:00')::timestamp)))::integer;
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM (aRow.away_end - pDayStart)))::integer;
                    WHEN (pNightOverlaps = false AND pDayOverlaps = false) AND (aRow.away_end IS NULL) AND (aRow.away_start BETWEEN pNightStart AND pNightEnd) THEN
                        -- does no overlap, goes out during the night time and never return
                        pNightAwayDurationTemp = (EXTRACT (EPOCH FROM (pDayStart - aRow.away_start)))::integer;
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM ((pDay || 'T' || '23:59')::timestamp - pDayStart)))::integer;
                    WHEN (pNightOverlaps = false AND pDayOverlaps = false) AND (aRow.away_end IS NULL) AND (aRow.away_start BETWEEN pDayStart AND pDayEnd) THEN
                        -- does no overlap, goes out during the day time and never return
                        pDayAwayDurationTemp = (EXTRACT (EPOCH FROM ((pDay || 'T' || '23:59')::timestamp - aRow.away_start)))::integer;
                END CASE;

              pDayAwayDuration = pDayAwayDuration + pDayAwayDurationTemp;
              pNightAwayDuration = pNightAwayDuration + pNightAwayDurationTemp;
            END LOOP;
          ELSE

            -- Check if user is at home.
            SELECT
              ey.event_type_id
              , ey.extra_data
            INTO
              lastUserEventTypeId
              , lastUserExtraData
            FROM eyecare ey
            WHERE
              ey.create_date BETWEEN (pDay  || 'T' || '00:00')::timestamp AND ((pDay || 'T' || '23:59')::timestamp) AND
              ey.device_id = pDeviceId
            ORDER BY ey.create_date DESC LIMIT 1;

            IF lastUserEventTypeId = '20001' AND extra_data = 'Alarm Off' THEN
              -- user is away from home for the whole day. Do no calculate at all
              pDayAwayDuration = null;
              pNightAwayDuration = null;
            ELSE
              -- user is at home for the whole day.
              pDayAwayDuration = 0;
              pNightAwayDuration = 0;
            END IF;
        END IF;

        -- Calculate the activity level
        IF (pNightDuration - pNightAwayDuration) > 0 THEN
          pNightActivityLevel = nActive * 100 / (pNightDuration - pNightAwayDuration);
        ELSE
          pNightActivityLevel = null;
        END IF;

        IF (pDayDuration - pDayAwayDuration) > 0 THEN
          pDayActivityLevel = dActive * 100 / (pDayDuration - pDayAwayDuration);
        ELSE
          pDayActivityLevel = null;
        END IF;
      ELSE
        -- if there are still no sleep time or wake up time, i am going home
        pDayActivityLevel = null;
        pNightActivityLevel = null;
      END IF;


      RETURN QUERY
        SELECT
          *
           , pWakeupTime
           , pSleepingTime
           , EXTRACT (HOUR FROM pSleepingTime)::integer
           , pDayDuration
           , pNightDuration
           , pDayAwayDuration
           , pNightAwayDuration
           , dActive
           , nActive
           , pDayActivityLevel
           , pNightActivityLevel
        FROM day_activities_temp;

  END;
  $BODY$
  LANGUAGE plpgsql;
