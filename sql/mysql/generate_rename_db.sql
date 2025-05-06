-- 1) Configure the old and new database names
SET @oldDb = 'test-before';
SET @newDb = 'test-after';

-- 2) Increase group_concat
SET SESSION group_concat_max_len = 4294967295;

-- 3) Generate the queries
SELECT CONCAT(
  '-- Step 0: Create the new database (if it does not exist)\n',
  'CREATE DATABASE IF NOT EXISTS `', @newDb, '` ',
  'CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n\n',

  '-- Step 1: Rename all BASE TABLES\n',
  COALESCE(
    (
      SELECT GROUP_CONCAT(
        CONCAT(
          'RENAME TABLE `', @oldDb, '`.`', TABLE_NAME,
          '` TO `', @newDb, '`.`', TABLE_NAME, '`;'
        ) SEPARATOR '\n'
      )
      FROM INFORMATION_SCHEMA.TABLES
      WHERE TABLE_SCHEMA = @oldDb
        AND TABLE_TYPE   = 'BASE TABLE'
    ),
    CONCAT('-- (No base tables found in ', @oldDb, ')')
  ), '\n\n',

  '-- Step 2: Re-create VIEWS\n',
  COALESCE(
    (
      SELECT GROUP_CONCAT(
        CONCAT(
          'CREATE OR REPLACE ',
          'DEFINER=', DEFINER, ' ',
          'SQL SECURITY ', SECURITY_TYPE, ' ',
          'VIEW `', @newDb, '`.`', TABLE_NAME, '` AS ', REPLACE(VIEW_DEFINITION, CONCAT('`', @oldDb, '`.'), CONCAT('`', @newDb, '`.')), ';'
        ) SEPARATOR '\n'
      )
      FROM INFORMATION_SCHEMA.VIEWS
      WHERE TABLE_SCHEMA = @oldDb
    ),
    CONCAT('-- (No views found in ', @oldDb, ')')
  ), '\n\n',

  '-- Step 3: Re-create TRIGGERS\n',
  COALESCE(
    (
      SELECT GROUP_CONCAT(
        CONCAT(
          'CREATE TRIGGER `', @newDb, '`.`', TRIGGER_NAME, '` ',
          ACTION_TIMING, ' ', EVENT_MANIPULATION, 
          ' ON `', @newDb, '`.`', EVENT_OBJECT_TABLE, '` ',
          'FOR EACH ROW ', ACTION_STATEMENT, ';'
        ) SEPARATOR '\n'
      )
      FROM INFORMATION_SCHEMA.TRIGGERS
      WHERE TRIGGER_SCHEMA = @oldDb
    ),
    CONCAT('-- (No triggers found in ', @oldDb, ')')
  ), '\n\n',

  '-- Step 4: Re-create STORED PROCEDURES\n',
  COALESCE(
    (
      SELECT GROUP_CONCAT(
        CONCAT(
          'CREATE DEFINER=', DEFINER, ' PROCEDURE `', @newDb, '`.`', ROUTINE_NAME, '`(',
          COALESCE(
            (
              SELECT GROUP_CONCAT(
                CONCAT(PARAMETER_MODE, ' `', PARAMETER_NAME, '` ', DTD_IDENTIFIER)
                ORDER BY ORDINAL_POSITION
                SEPARATOR ', '
              )
              FROM INFORMATION_SCHEMA.PARAMETERS
              WHERE SPECIFIC_SCHEMA = @oldDb
                AND SPECIFIC_NAME   = ROUTINE_NAME
            ),
            ''
          ),
          ') ',
          CASE WHEN SQL_DATA_ACCESS IS NOT NULL THEN CONCAT(SQL_DATA_ACCESS, ' ') ELSE '' END,
          CASE WHEN SECURITY_TYPE   IS NOT NULL THEN CONCAT('SQL SECURITY ', SECURITY_TYPE, ' ') ELSE '' END,
          ROUTINE_DEFINITION,
          ';'
        ) SEPARATOR '\n'
      )
      FROM INFORMATION_SCHEMA.ROUTINES
      WHERE ROUTINE_SCHEMA = @oldDb
        AND ROUTINE_TYPE   = 'PROCEDURE'
    ),
    CONCAT('-- (No procedures found in ', @oldDb, ')')
  ), '\n\n',

  '-- Step 5: Re-create STORED FUNCTIONS\n',
  COALESCE(
    (
      SELECT GROUP_CONCAT(
        CONCAT(
          'CREATE DEFINER=', DEFINER, ' FUNCTION `', @newDb, '`.`', ROUTINE_NAME, '`(',
          COALESCE(
            (
              SELECT GROUP_CONCAT(
                CONCAT(PARAMETER_MODE, ' `', PARAMETER_NAME, '` ', DTD_IDENTIFIER)
                ORDER BY ORDINAL_POSITION
                SEPARATOR ', '
              )
              FROM INFORMATION_SCHEMA.PARAMETERS
              WHERE SPECIFIC_SCHEMA = @oldDb
                AND SPECIFIC_NAME   = ROUTINE_NAME
            ),
            ''
          ),
          ') RETURNS ', DTD_IDENTIFIER, ' ',
          CASE WHEN SQL_DATA_ACCESS IS NOT NULL THEN CONCAT(SQL_DATA_ACCESS, ' ') ELSE '' END,
          CASE WHEN SECURITY_TYPE   IS NOT NULL THEN CONCAT('SQL SECURITY ', SECURITY_TYPE, ' ') ELSE '' END,
          ROUTINE_DEFINITION,
          ';'
        ) SEPARATOR '\n'
      )
      FROM INFORMATION_SCHEMA.ROUTINES
      WHERE ROUTINE_SCHEMA = @oldDb
        AND ROUTINE_TYPE   = 'FUNCTION'
    ),
    CONCAT('-- (No functions found in ', @oldDb, ')')
  ), '\n\n',

  '-- Step 6: Re-create EVENTS\n',
  COALESCE(
    (
      SELECT GROUP_CONCAT(
        CONCAT(
          'CREATE DEFINER=', DEFINER,
          ' EVENT `', @newDb, '`.`', EVENT_NAME, '`',
          ' ON SCHEDULE ',
          CASE 
            WHEN EVENT_TYPE = 'RECURRING' THEN CONCAT(
              'EVERY ', INTERVAL_VALUE, ' ', INTERVAL_FIELD,
              IF(STARTS IS NOT NULL, CONCAT(' STARTS \'', STARTS, '\''), ''),
              IF(ENDS   IS NOT NULL, CONCAT(' ENDS \'',   ENDS,   '\''), '')
            )
            ELSE CONCAT('AT \'', EXECUTE_AT, '\'')
          END,
          ' ON COMPLETION ', ON_COMPLETION, ' ',
          CASE STATUS
            WHEN 'ENABLED'            THEN 'ENABLE'
            WHEN 'DISABLED'           THEN 'DISABLE'
            WHEN 'SLAVESIDE_DISABLED' THEN 'DISABLE ON SLAVE'
            ELSE 'ENABLE'
          END,
          IF(EVENT_COMMENT IS NOT NULL AND EVENT_COMMENT <> '',
             CONCAT(' COMMENT \'', REPLACE(EVENT_COMMENT, '\'', '\\\''), '\''),
             ''
          ),
          ' DO ', EVENT_DEFINITION, ';'
        ) SEPARATOR '\n'
      )
      FROM INFORMATION_SCHEMA.EVENTS
      WHERE EVENT_SCHEMA = @oldDb
    ),
    CONCAT('-- (No events found in ', @oldDb, ')')
  ), '\n\n',

  '-- Step 7: Re-apply DATABASE-LEVEL PRIVILEGES (mysql.db)\n',
  COALESCE(
    (
      SELECT GROUP_CONCAT(
        CONCAT(
          -- The GRANT uses newDb (escape underscores as required in mysql <= 8)
          'GRANT ',
          IF(dbpriv.privilege_list = '', 'USAGE', dbpriv.privilege_list),
          ' ON `', REPLACE(@newDb, '_', '\\_'), '`.* TO `', dbpriv.User, '`@`', dbpriv.Host, '`',
          IF(dbpriv.grant_option = 'Y', ' WITH GRANT OPTION', ''),
          ';\n',
          -- The REVOKE uses the exact old DB name from the row (escaped).
          'REVOKE ',
					IF(dbpriv.grant_option = 'Y', 'GRANT OPTION,', ''),
          IF(dbpriv.privilege_list = '', 'USAGE', dbpriv.privilege_list),
          ' ON `', dbpriv.Db, '`.* FROM `', dbpriv.User, '`@`', dbpriv.Host, '`;\n'
        )
        SEPARATOR '\n'
      )
      FROM (
        SELECT 
          Db,
          User,
          Host,
          Grant_priv AS grant_option,
          CONCAT_WS(',',
            IF(Select_priv='Y','SELECT',NULL),
            IF(Insert_priv='Y','INSERT',NULL),
            IF(Update_priv='Y','UPDATE',NULL),
            IF(Delete_priv='Y','DELETE',NULL),
            IF(Create_priv='Y','CREATE',NULL),
            IF(Drop_priv='Y','DROP',NULL),
            IF(References_priv='Y','REFERENCES',NULL),
            IF(Index_priv='Y','INDEX',NULL),
            IF(Alter_priv='Y','ALTER',NULL),
            IF(Create_tmp_table_priv='Y','CREATE TEMPORARY TABLES',NULL),
            IF(Lock_tables_priv='Y','LOCK TABLES',NULL),
            IF(Create_view_priv='Y','CREATE VIEW',NULL),
            IF(Show_view_priv='Y','SHOW VIEW',NULL),
            IF(Create_routine_priv='Y','CREATE ROUTINE',NULL),
            IF(Alter_routine_priv='Y','ALTER ROUTINE',NULL),
            IF(Execute_priv='Y','EXECUTE',NULL),
            IF(Event_priv='Y','EVENT',NULL),
            IF(Trigger_priv='Y','TRIGGER',NULL)
          ) AS privilege_list
        FROM mysql.db
        WHERE (
          BINARY Db = @oldDb
          OR BINARY Db = REPLACE(@oldDb, '_', '\\_')
        )
          AND (
            Select_priv='Y' OR Insert_priv='Y' OR Update_priv='Y' OR Delete_priv='Y'
            OR Create_priv='Y' OR Drop_priv='Y' OR Grant_priv='Y' OR References_priv='Y'
            OR Index_priv='Y'  OR Alter_priv='Y' OR Create_tmp_table_priv='Y'
            OR Lock_tables_priv='Y' OR Create_view_priv='Y' OR Show_view_priv='Y'
            OR Create_routine_priv='Y' OR Alter_routine_priv='Y'
            OR Execute_priv='Y' OR Event_priv='Y' OR Trigger_priv='Y'
          )
      ) AS dbpriv
    ),
    CONCAT('-- (No db-level privileges found in ', @oldDb, ' to replicate)')
  ), '\n\n',

  '-- Step 8: Re-apply TABLE-LEVEL PRIVILEGES (mysql.tables_priv)\n',
  COALESCE(
    (
      SELECT GROUP_CONCAT(
        CONCAT(
          -- GRANT uses newDb and the same table name
          'GRANT ',
          'IF(tablepriv.privilege_list = \'\', \'USAGE\', tablepriv.privilege_list)',
          ' ON `', REPLACE(@newDb, '_', '\\_'), '`.`', tablepriv.Table_name, '` TO `', tablepriv.User, '`@`', tablepriv.Host, '`',
          IF(tablepriv.has_grant_option, ' WITH GRANT OPTION', ''),
          ';\n',
          -- REVOKE uses the exact stored Db from the row
          'REVOKE ',
					IF(tablepriv.has_grant_option, 'GRANT OPTION,', ''),
          'IF(tablepriv.privilege_list = \'\', \'USAGE\', tablepriv.privilege_list)',
          ' ON `', tablepriv.Db, '`.`', tablepriv.Table_name, '` FROM `',
            tablepriv.User, '`@`', tablepriv.Host, '`;\n'
        )
        SEPARATOR '\n'
      )
      FROM (
        SELECT 
          Db,
          Host,
          User,
          Table_name,
          (FIND_IN_SET('Grant', Table_priv) > 0) AS has_grant_option,
          CONCAT_WS(',',
            IF(FIND_IN_SET('Select',        Table_priv) > 0, 'SELECT', NULL),
            IF(FIND_IN_SET('Insert',        Table_priv) > 0, 'INSERT', NULL),
            IF(FIND_IN_SET('Update',        Table_priv) > 0, 'UPDATE', NULL),
            IF(FIND_IN_SET('Delete',        Table_priv) > 0, 'DELETE', NULL),
            IF(FIND_IN_SET('Create',        Table_priv) > 0, 'CREATE', NULL),
            IF(FIND_IN_SET('Drop',          Table_priv) > 0, 'DROP', NULL),
            IF(FIND_IN_SET('References',    Table_priv) > 0, 'REFERENCES', NULL),
            IF(FIND_IN_SET('Index',         Table_priv) > 0, 'INDEX', NULL),
            IF(FIND_IN_SET('Alter',         Table_priv) > 0, 'ALTER', NULL),
            IF(FIND_IN_SET('Create View',   Table_priv) > 0, 'CREATE VIEW', NULL),
            IF(FIND_IN_SET('Show view',     Table_priv) > 0, 'SHOW VIEW', NULL),
            IF(FIND_IN_SET('Trigger',       Table_priv) > 0, 'TRIGGER', NULL)
          ) AS privilege_list
        FROM mysql.tables_priv
        WHERE (
          BINARY Db = @oldDb
          OR BINARY Db = REPLACE(@oldDb, '_', '\\_')
        )
          AND Table_priv <> ''
      ) AS tablepriv
    ),
    CONCAT('-- (No table-level privileges found in ', @oldDb, ' to replicate)')
  ), '\n\n',

  '-- Step 9: Drop the old database\n',
  '#DROP DATABASE `', @oldDb, '`;\n'
) AS rename_script;
