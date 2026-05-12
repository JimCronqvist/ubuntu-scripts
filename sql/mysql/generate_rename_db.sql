-- generate_rename_db.sql
--
-- SQL generator for mysql_rename_db.sh. Can also be used standalone as well.
--
-- This file returns exactly one row/column: the SQL migration script to execute.
--
-- Configuration:
--   When running this file directly, uncomment and edit these values:
--
--   SET @oldDb = 'old_database';  # <-------------------------------- Change here if not using bash script
--   SET @newDb = 'new_database';  # <-------------------------------- Change here if not using bash script
--
--   SET @copyGrants = 1;
--   SET @revokeOldGrants = 1;
--
--   When running through mysql_rename_db.sh, the Bash wrapper prepends these
--   values automatically and overrides the defaults below.
--
-- Defaults:
--   @copyGrants and @revokeOldGrants default to 1 for standalone usage behavior.
--   The Bash wrapper explicitly sets them to 0 unless the matching CLI options are passed.
--
-- Compatibility target:
--   This generator targets MySQL grant-table metadata. MariaDB may differ.

SET SESSION group_concat_max_len = 4294967295;

SET @copyGrants = IFNULL(@copyGrants, 1);
SET @revokeOldGrants = IFNULL(@revokeOldGrants, 1);
SET @configError = IF(
  @oldDb IS NULL OR @newDb IS NULL OR @oldDb = '' OR @newDb = '',
  '-- ERROR: @oldDb and @newDb must be set. Uncomment the config section at the top, or run through mysql_rename_db.sh.\n',
  NULL
);

SET @oldDbIdent = CONCAT('`', @oldDb, '`');
SET @newDbIdent = CONCAT('`', @newDb, '`');

-- GRANT database names support _/% wildcards. Escape those when generating grant scopes.
SET @oldDbGrantIdent = CONCAT('`', REPLACE(REPLACE(@oldDb, '_', '\\_'), '%', '\\%'), '`');
SET @newDbGrantIdent = CONCAT('`', REPLACE(REPLACE(@newDb, '_', '\\_'), '%', '\\%'), '`');

SET @oldDbDotted = CONCAT('`', @oldDb, '`.');
SET @newDbDotted = CONCAT('`', @newDb, '`.');

SET @oldDbGrantPattern = REPLACE(REPLACE(@oldDb, '_', '\\_'), '%', '\\%');

SET @headerSection = CONCAT(
  '-- Generated database rename SQL\n',
  '-- Old database: ', @oldDb, '\n',
  '-- New database: ', @newDb, '\n',
  '-- Copy grants: ', @copyGrants, '\n',
  '-- Revoke old grants: ', @revokeOldGrants, '\n\n',
  'SET @OLD_FOREIGN_KEY_CHECKS = @@FOREIGN_KEY_CHECKS;\n',
  'SET @OLD_UNIQUE_CHECKS = @@UNIQUE_CHECKS;\n',
  'SET FOREIGN_KEY_CHECKS = 0;\n',
  'SET UNIQUE_CHECKS = 0;\n\n'
);

SELECT COALESCE(
  (
    SELECT CONCAT(
      '-- Step 1: Create the new database with the old database defaults\n',
      'CREATE DATABASE ', @newDbIdent,
      ' DEFAULT CHARACTER SET ', DEFAULT_CHARACTER_SET_NAME,
      ' DEFAULT COLLATE ', DEFAULT_COLLATION_NAME,
      ';\n'
    )
    FROM INFORMATION_SCHEMA.SCHEMATA
    WHERE SCHEMA_NAME = @oldDb
  ),
  CONCAT('-- Step 1: old database not found: ', @oldDb, '\n')
) INTO @createDatabaseSection;

SELECT CONCAT(
  '-- Step 2: Drop old triggers before cross-database table rename\n',
  COALESCE(
    (
      SELECT GROUP_CONCAT(
        CONCAT(
          'DROP TRIGGER ', @oldDbIdent, '.`', TRIGGER_NAME, '`;'
        )
        ORDER BY EVENT_OBJECT_TABLE, ACTION_ORDER, TRIGGER_NAME
        SEPARATOR '\n'
      )
      FROM INFORMATION_SCHEMA.TRIGGERS
      WHERE TRIGGER_SCHEMA = @oldDb
    ),
    CONCAT('-- (No triggers found in ', @oldDb, ')')
  ),
  '\n'
) INTO @dropOldTriggersSection;

SELECT CONCAT(
  '-- Step 3: Rename all base tables\n',
  COALESCE(
    (
      SELECT GROUP_CONCAT(
        CONCAT(
          'RENAME TABLE ',
          @oldDbIdent, '.`', TABLE_NAME, '`',
          ' TO ',
          @newDbIdent, '.`', TABLE_NAME, '`;'
        )
        ORDER BY TABLE_NAME
        SEPARATOR '\n'
      )
      FROM INFORMATION_SCHEMA.TABLES
      WHERE TABLE_SCHEMA = @oldDb
        AND TABLE_TYPE = 'BASE TABLE'
    ),
    CONCAT('-- (No base tables found in ', @oldDb, ')')
  ),
  '\n'
) INTO @renameBaseTablesSection;

SELECT CONCAT(
  '-- Step 7: Re-create triggers in the new database\n',
  COALESCE(
    (
      SELECT CONCAT(
        'DELIMITER $$\n',
        GROUP_CONCAT(
          CONCAT(
            'CREATE DEFINER=',
            '`', SUBSTRING_INDEX(DEFINER, '@', 1), '`@`',
            SUBSTRING_INDEX(DEFINER, '@', -1), '` ',
            'TRIGGER ', @newDbIdent, '.`', TRIGGER_NAME, '` ',
            ACTION_TIMING, ' ', EVENT_MANIPULATION,
            ' ON ', @newDbIdent, '.`', EVENT_OBJECT_TABLE, '` ',
            'FOR EACH ROW ',
            REPLACE(ACTION_STATEMENT, @oldDbDotted, @newDbDotted),
            '$$'
          )
          ORDER BY EVENT_OBJECT_TABLE, ACTION_ORDER, TRIGGER_NAME
          SEPARATOR '\n'
        ),
        '\nDELIMITER ;'
      )
      FROM INFORMATION_SCHEMA.TRIGGERS
      WHERE TRIGGER_SCHEMA = @oldDb
    ),
    CONCAT('-- (No triggers found in ', @oldDb, ')')
  ),
  '\n'
) INTO @createTriggersSection;

SELECT CONCAT(
  '-- Step 6: Re-create views in the new database\n',
  COALESCE(
    (
      SELECT GROUP_CONCAT(
        CONCAT(
          'CREATE OR REPLACE ',
          'DEFINER=',
          '`', SUBSTRING_INDEX(DEFINER, '@', 1), '`@`',
          SUBSTRING_INDEX(DEFINER, '@', -1), '` ',
          'SQL SECURITY ', SECURITY_TYPE, ' ',
          'VIEW ', @newDbIdent, '.`', TABLE_NAME, '` AS ',
          REPLACE(VIEW_DEFINITION, @oldDbDotted, @newDbDotted),
          CASE
            WHEN CHECK_OPTION IS NULL OR CHECK_OPTION = 'NONE' THEN ''
            ELSE CONCAT(' WITH ', CHECK_OPTION, ' CHECK OPTION')
          END,
          ';'
        )
        ORDER BY TABLE_NAME
        SEPARATOR '\n'
      )
      FROM INFORMATION_SCHEMA.VIEWS
      WHERE TABLE_SCHEMA = @oldDb
    ),
    CONCAT('-- (No views found in ', @oldDb, ')')
  ),
  '\n'
) INTO @createViewsSection;

SELECT CONCAT(
  '-- Step 13: Drop old views\n',
  COALESCE(
    (
      SELECT GROUP_CONCAT(
        CONCAT(
          'DROP VIEW ', @oldDbIdent, '.`', TABLE_NAME, '`;'
        )
        ORDER BY TABLE_NAME
        SEPARATOR '\n'
      )
      FROM INFORMATION_SCHEMA.VIEWS
      WHERE TABLE_SCHEMA = @oldDb
    ),
    CONCAT('-- (No views found in ', @oldDb, ')')
  ),
  '\n'
) INTO @dropOldViewsSection;

SELECT CONCAT(
  '-- Step 4: Re-create stored procedures in the new database\n',
  COALESCE(
    (
      SELECT CONCAT(
        'DELIMITER $$\n',
        GROUP_CONCAT(
          CONCAT(
            'CREATE DEFINER=',
            '`', SUBSTRING_INDEX(r.DEFINER, '@', 1), '`@`',
            SUBSTRING_INDEX(r.DEFINER, '@', -1), '` ',
            'PROCEDURE ', @newDbIdent, '.`', r.ROUTINE_NAME, '`(',
            COALESCE(
              (
                SELECT GROUP_CONCAT(
                  CONCAT(
                    IF(p.PARAMETER_MODE IS NULL OR p.PARAMETER_MODE = '', '', CONCAT(p.PARAMETER_MODE, ' ')),
                    '`', p.PARAMETER_NAME, '` ',
                    p.DTD_IDENTIFIER
                  )
                  ORDER BY p.ORDINAL_POSITION
                  SEPARATOR ', '
                )
                FROM INFORMATION_SCHEMA.PARAMETERS p
                WHERE p.SPECIFIC_SCHEMA = r.ROUTINE_SCHEMA
                  AND p.SPECIFIC_NAME = r.SPECIFIC_NAME
                  AND p.PARAMETER_NAME IS NOT NULL
              ),
              ''
            ),
            ') ',
            'LANGUAGE SQL ',
            CASE WHEN r.IS_DETERMINISTIC = 'YES' THEN 'DETERMINISTIC ' ELSE 'NOT DETERMINISTIC ' END,
            IF(r.SQL_DATA_ACCESS IS NULL OR r.SQL_DATA_ACCESS = '', '', CONCAT(r.SQL_DATA_ACCESS, ' ')),
            IF(r.SECURITY_TYPE IS NULL OR r.SECURITY_TYPE = '', '', CONCAT('SQL SECURITY ', r.SECURITY_TYPE, ' ')),
            IF(r.ROUTINE_COMMENT IS NULL OR r.ROUTINE_COMMENT = '', '', CONCAT('COMMENT ', QUOTE(r.ROUTINE_COMMENT), ' ')),
            REPLACE(r.ROUTINE_DEFINITION, @oldDbDotted, @newDbDotted),
            '$$'
          )
          ORDER BY r.ROUTINE_NAME
          SEPARATOR '\n'
        ),
        '\nDELIMITER ;'
      )
      FROM INFORMATION_SCHEMA.ROUTINES r
      WHERE r.ROUTINE_SCHEMA = @oldDb
        AND r.ROUTINE_TYPE = 'PROCEDURE'
    ),
    CONCAT('-- (No procedures found in ', @oldDb, ')')
  ),
  '\n'
) INTO @createProceduresSection;

SELECT CONCAT(
  '-- Step 5: Re-create stored functions in the new database\n',
  COALESCE(
    (
      SELECT CONCAT(
        'DELIMITER $$\n',
        GROUP_CONCAT(
          CONCAT(
            'CREATE DEFINER=',
            '`', SUBSTRING_INDEX(r.DEFINER, '@', 1), '`@`',
            SUBSTRING_INDEX(r.DEFINER, '@', -1), '` ',
            'FUNCTION ', @newDbIdent, '.`', r.ROUTINE_NAME, '`(',
            COALESCE(
              (
                SELECT GROUP_CONCAT(
                  CONCAT(
                    '`', p.PARAMETER_NAME, '` ',
                    p.DTD_IDENTIFIER
                  )
                  ORDER BY p.ORDINAL_POSITION
                  SEPARATOR ', '
                )
                FROM INFORMATION_SCHEMA.PARAMETERS p
                WHERE p.SPECIFIC_SCHEMA = r.ROUTINE_SCHEMA
                  AND p.SPECIFIC_NAME = r.SPECIFIC_NAME
                  AND p.PARAMETER_NAME IS NOT NULL
              ),
              ''
            ),
            ') RETURNS ', r.DTD_IDENTIFIER, ' ',
            'LANGUAGE SQL ',
            CASE WHEN r.IS_DETERMINISTIC = 'YES' THEN 'DETERMINISTIC ' ELSE 'NOT DETERMINISTIC ' END,
            IF(r.SQL_DATA_ACCESS IS NULL OR r.SQL_DATA_ACCESS = '', '', CONCAT(r.SQL_DATA_ACCESS, ' ')),
            IF(r.SECURITY_TYPE IS NULL OR r.SECURITY_TYPE = '', '', CONCAT('SQL SECURITY ', r.SECURITY_TYPE, ' ')),
            IF(r.ROUTINE_COMMENT IS NULL OR r.ROUTINE_COMMENT = '', '', CONCAT('COMMENT ', QUOTE(r.ROUTINE_COMMENT), ' ')),
            REPLACE(r.ROUTINE_DEFINITION, @oldDbDotted, @newDbDotted),
            '$$'
          )
          ORDER BY r.ROUTINE_NAME
          SEPARATOR '\n'
        ),
        '\nDELIMITER ;'
      )
      FROM INFORMATION_SCHEMA.ROUTINES r
      WHERE r.ROUTINE_SCHEMA = @oldDb
        AND r.ROUTINE_TYPE = 'FUNCTION'
    ),
    CONCAT('-- (No functions found in ', @oldDb, ')')
  ),
  '\n'
) INTO @createFunctionsSection;

SELECT CONCAT(
  '-- Step 15: Drop old stored procedures and functions\n',
  COALESCE(
    (
      SELECT GROUP_CONCAT(
        CONCAT(
          'DROP ', r.ROUTINE_TYPE, ' ', @oldDbIdent, '.`', r.ROUTINE_NAME, '`;'
        )
        ORDER BY r.ROUTINE_TYPE, r.ROUTINE_NAME
        SEPARATOR '\n'
      )
      FROM INFORMATION_SCHEMA.ROUTINES r
      WHERE r.ROUTINE_SCHEMA = @oldDb
    ),
    CONCAT('-- (No routines found in ', @oldDb, ')')
  ),
  '\n'
) INTO @dropOldRoutinesSection;

SELECT CONCAT(
  '-- Step 8: Re-create events in the new database\n',
  COALESCE(
    (
      SELECT CONCAT(
        'DELIMITER $$\n',
        GROUP_CONCAT(
          CONCAT(
            'CREATE DEFINER=',
            '`', SUBSTRING_INDEX(e.DEFINER, '@', 1), '`@`',
            SUBSTRING_INDEX(e.DEFINER, '@', -1), '` ',
            'EVENT ', @newDbIdent, '.`', e.EVENT_NAME, '` ',
            'ON SCHEDULE ',
            CASE
              WHEN e.EVENT_TYPE = 'RECURRING' THEN CONCAT(
                'EVERY ', e.INTERVAL_VALUE, ' ', e.INTERVAL_FIELD,
                IF(e.STARTS IS NOT NULL, CONCAT(' STARTS ', QUOTE(DATE_FORMAT(e.STARTS, '%Y-%m-%d %H:%i:%s'))), ''),
                IF(e.ENDS IS NOT NULL, CONCAT(' ENDS ', QUOTE(DATE_FORMAT(e.ENDS, '%Y-%m-%d %H:%i:%s'))), '')
              )
              ELSE CONCAT('AT ', QUOTE(DATE_FORMAT(e.EXECUTE_AT, '%Y-%m-%d %H:%i:%s')))
            END,
            ' ON COMPLETION ', e.ON_COMPLETION, ' ',
            CASE e.STATUS
              WHEN 'ENABLED' THEN 'ENABLE'
              WHEN 'DISABLED' THEN 'DISABLE'
              WHEN 'SLAVESIDE_DISABLED' THEN 'DISABLE ON SLAVE'
              ELSE 'ENABLE'
            END,
            IF(e.EVENT_COMMENT IS NULL OR e.EVENT_COMMENT = '', '', CONCAT(' COMMENT ', QUOTE(e.EVENT_COMMENT))),
            ' DO ',
            REPLACE(e.EVENT_DEFINITION, @oldDbDotted, @newDbDotted),
            '$$'
          )
          ORDER BY e.EVENT_NAME
          SEPARATOR '\n'
        ),
        '\nDELIMITER ;'
      )
      FROM INFORMATION_SCHEMA.EVENTS e
      WHERE e.EVENT_SCHEMA = @oldDb
    ),
    CONCAT('-- (No events found in ', @oldDb, ')')
  ),
  '\n'
) INTO @createEventsSection;

SELECT CONCAT(
  '-- Step 14: Drop old events\n',
  COALESCE(
    (
      SELECT GROUP_CONCAT(
        CONCAT(
          'DROP EVENT ', @oldDbIdent, '.`', EVENT_NAME, '`;'
        )
        ORDER BY EVENT_NAME
        SEPARATOR '\n'
      )
      FROM INFORMATION_SCHEMA.EVENTS
      WHERE EVENT_SCHEMA = @oldDb
    ),
    CONCAT('-- (No events found in ', @oldDb, ')')
  ),
  '\n'
) INTO @dropOldEventsSection;

SELECT CONCAT(
  '-- Step 9: Database-level grants and revokes\n',
  COALESCE(
    (
      SELECT GROUP_CONCAT(
        CONCAT(
          IF(
            @copyGrants = 1,
            CASE
              WHEN dbpriv.privilege_list <> '' THEN CONCAT(
                'GRANT ', dbpriv.privilege_list,
                ' ON ', @newDbGrantIdent, '.* TO ', dbpriv.account,
                IF(dbpriv.has_grant_option = 1, ' WITH GRANT OPTION', ''),
                ';\n'
              )
              WHEN dbpriv.has_grant_option = 1 THEN CONCAT(
                'GRANT USAGE ON ', @newDbGrantIdent, '.* TO ', dbpriv.account,
                ' WITH GRANT OPTION;\n'
              )
              ELSE ''
            END,
            ''
          ),
          IF(
            @revokeOldGrants = 1,
            CONCAT(
              'REVOKE ',
              CONCAT_WS(', ', IF(dbpriv.has_grant_option = 1, 'GRANT OPTION', NULL), NULLIF(dbpriv.privilege_list, '')),
              ' ON `', dbpriv.Db, '`.* FROM ', dbpriv.account,
              ';\n'
            ),
            ''
          ),
          '\n'
        )
        ORDER BY dbpriv.User, dbpriv.Host, dbpriv.Db
        SEPARATOR ''
      )
      FROM (
        SELECT
          Db,
          User,
          Host,
          Grant_priv = 'Y' AS has_grant_option,
          CONCAT(QUOTE(User), '@', QUOTE(Host)) AS account,
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
        WHERE (BINARY Db = @oldDb OR BINARY Db = @oldDbGrantPattern)
          AND (
            Select_priv='Y' OR Insert_priv='Y' OR Update_priv='Y' OR Delete_priv='Y' OR
            Create_priv='Y' OR Drop_priv='Y' OR Grant_priv='Y' OR References_priv='Y' OR
            Index_priv='Y' OR Alter_priv='Y' OR Create_tmp_table_priv='Y' OR Lock_tables_priv='Y' OR
            Create_view_priv='Y' OR Show_view_priv='Y' OR Create_routine_priv='Y' OR
            Alter_routine_priv='Y' OR Execute_priv='Y' OR Event_priv='Y' OR Trigger_priv='Y'
          )
      ) AS dbpriv
    ),
    CONCAT('-- (No database-level privileges found in ', @oldDb, ')\n')
  )
) INTO @databaseGrantSection;

SELECT CONCAT(
  '-- Step 10: Table/view-level grants and revokes\n',
  COALESCE(
    (
      SELECT GROUP_CONCAT(
        CONCAT(
          IF(
            @copyGrants = 1,
            CASE
              WHEN tablepriv.privilege_list <> '' THEN CONCAT(
                'GRANT ', tablepriv.privilege_list,
                ' ON ', @newDbGrantIdent, '.`', tablepriv.Table_name, '` TO ', tablepriv.account,
                IF(tablepriv.has_grant_option = 1, ' WITH GRANT OPTION', ''),
                ';\n'
              )
              ELSE ''
            END,
            ''
          ),
          IF(
            @revokeOldGrants = 1,
            CONCAT(
              'REVOKE ',
              CONCAT_WS(', ', IF(tablepriv.has_grant_option = 1, 'GRANT OPTION', NULL), NULLIF(tablepriv.privilege_list, '')),
              ' ON `', tablepriv.Db, '`.`', tablepriv.Table_name, '` FROM ', tablepriv.account,
              ';\n'
            ),
            ''
          ),
          '\n'
        )
        ORDER BY tablepriv.User, tablepriv.Host, tablepriv.Db, tablepriv.Table_name
        SEPARATOR ''
      )
      FROM (
        SELECT
          Db,
          Host,
          User,
          Table_name,
          FIND_IN_SET('Grant', Table_priv) > 0 AS has_grant_option,
          CONCAT(QUOTE(User), '@', QUOTE(Host)) AS account,
          CONCAT_WS(',',
            IF(FIND_IN_SET('Select', Table_priv) > 0, 'SELECT', NULL),
            IF(FIND_IN_SET('Insert', Table_priv) > 0, 'INSERT', NULL),
            IF(FIND_IN_SET('Update', Table_priv) > 0, 'UPDATE', NULL),
            IF(FIND_IN_SET('Delete', Table_priv) > 0, 'DELETE', NULL),
            IF(FIND_IN_SET('Create', Table_priv) > 0, 'CREATE', NULL),
            IF(FIND_IN_SET('Drop', Table_priv) > 0, 'DROP', NULL),
            IF(FIND_IN_SET('References', Table_priv) > 0, 'REFERENCES', NULL),
            IF(FIND_IN_SET('Index', Table_priv) > 0, 'INDEX', NULL),
            IF(FIND_IN_SET('Alter', Table_priv) > 0, 'ALTER', NULL),
            IF(FIND_IN_SET('Create View', Table_priv) > 0, 'CREATE VIEW', NULL),
            IF(FIND_IN_SET('Show View', Table_priv) > 0 OR FIND_IN_SET('Show view', Table_priv) > 0, 'SHOW VIEW', NULL),
            IF(FIND_IN_SET('Trigger', Table_priv) > 0, 'TRIGGER', NULL)
          ) AS privilege_list
        FROM mysql.tables_priv
        WHERE (BINARY Db = @oldDb OR BINARY Db = @oldDbGrantPattern)
          AND Table_priv <> ''
      ) AS tablepriv
    ),
    CONCAT('-- (No table/view-level privileges found in ', @oldDb, ')\n')
  )
) INTO @tableGrantSection;

SELECT CONCAT(
  '-- Step 11: Column-level grants and revokes\n',
  COALESCE(
    (
      SELECT GROUP_CONCAT(
        CONCAT(
          IF(
            @copyGrants = 1,
            CONCAT(
              'GRANT ', columnpriv.privilege_list,
              ' ON ', @newDbGrantIdent, '.`', columnpriv.Table_name, '` TO ', columnpriv.account,
              ';\n'
            ),
            ''
          ),
          IF(
            @revokeOldGrants = 1,
            CONCAT(
              'REVOKE ', columnpriv.privilege_list,
              ' ON `', columnpriv.Db, '`.`', columnpriv.Table_name, '` FROM ', columnpriv.account,
              ';\n'
            ),
            ''
          ),
          '\n'
        )
        ORDER BY columnpriv.User, columnpriv.Host, columnpriv.Db, columnpriv.Table_name, columnpriv.Column_name
        SEPARATOR ''
      )
      FROM (
        SELECT
          Db,
          Host,
          User,
          Table_name,
          Column_name,
          CONCAT(QUOTE(User), '@', QUOTE(Host)) AS account,
          CONCAT_WS(',',
            IF(FIND_IN_SET('Select', Column_priv) > 0, CONCAT('SELECT (`', Column_name, '`)'), NULL),
            IF(FIND_IN_SET('Insert', Column_priv) > 0, CONCAT('INSERT (`', Column_name, '`)'), NULL),
            IF(FIND_IN_SET('Update', Column_priv) > 0, CONCAT('UPDATE (`', Column_name, '`)'), NULL),
            IF(FIND_IN_SET('References', Column_priv) > 0, CONCAT('REFERENCES (`', Column_name, '`)'), NULL)
          ) AS privilege_list
        FROM mysql.columns_priv
        WHERE (BINARY Db = @oldDb OR BINARY Db = @oldDbGrantPattern)
          AND Column_priv <> ''
      ) AS columnpriv
    ),
    CONCAT('-- (No column-level privileges found in ', @oldDb, ')\n')
  )
) INTO @columnGrantSection;

SELECT CONCAT(
  '-- Step 12: Routine-level grants and revokes\n',
  COALESCE(
    (
      SELECT GROUP_CONCAT(
        CONCAT(
          IF(
            @copyGrants = 1,
            CASE
              WHEN routinepriv.privilege_list <> '' THEN CONCAT(
                'GRANT ', routinepriv.privilege_list,
                ' ON ', routinepriv.Routine_type, ' ', @newDbGrantIdent, '.`', routinepriv.Routine_name, '` TO ', routinepriv.account,
                IF(routinepriv.has_grant_option = 1, ' WITH GRANT OPTION', ''),
                ';\n'
              )
              ELSE ''
            END,
            ''
          ),
          IF(
            @revokeOldGrants = 1,
            CONCAT(
              'REVOKE ',
              CONCAT_WS(', ', IF(routinepriv.has_grant_option = 1, 'GRANT OPTION', NULL), NULLIF(routinepriv.privilege_list, '')),
              ' ON ', routinepriv.Routine_type, ' `', routinepriv.Db, '`.`', routinepriv.Routine_name, '` FROM ', routinepriv.account,
              ';\n'
            ),
            ''
          ),
          '\n'
        )
        ORDER BY routinepriv.User, routinepriv.Host, routinepriv.Db, routinepriv.Routine_name
        SEPARATOR ''
      )
      FROM (
        SELECT
          Db,
          Host,
          User,
          Routine_name,
          Routine_type,
          FIND_IN_SET('Grant', Proc_priv) > 0 AS has_grant_option,
          CONCAT(QUOTE(User), '@', QUOTE(Host)) AS account,
          CONCAT_WS(',',
            IF(FIND_IN_SET('Execute', Proc_priv) > 0, 'EXECUTE', NULL),
            IF(FIND_IN_SET('Alter Routine', Proc_priv) > 0, 'ALTER ROUTINE', NULL)
          ) AS privilege_list
        FROM mysql.procs_priv
        WHERE (BINARY Db = @oldDb OR BINARY Db = @oldDbGrantPattern)
          AND Proc_priv <> ''
      ) AS routinepriv
    ),
    CONCAT('-- (No routine-level privileges found in ', @oldDb, ')\n')
  )
) INTO @routineGrantSection;

SET @grantSection = IF(
  @copyGrants = 1 OR @revokeOldGrants = 1,
  CONCAT(
    @databaseGrantSection, '\n',
    @tableGrantSection, '\n',
    @columnGrantSection, '\n',
    @routineGrantSection, '\n'
  ),
  '-- Step 9-12: Grant handling disabled\n'
);

SET @footerSection = CONCAT(
  '-- Final step is performed by the Bash wrapper:\n',
  '--   1. verify the old database has zero remaining objects\n',
  '--   2. DROP DATABASE ', @oldDbIdent, '\n\n',
  'SET FOREIGN_KEY_CHECKS = @OLD_FOREIGN_KEY_CHECKS;\n',
  'SET UNIQUE_CHECKS = @OLD_UNIQUE_CHECKS;\n'
);

SELECT IF(
  @configError IS NOT NULL,
  @configError,
  CONCAT(
  @headerSection,
  @createDatabaseSection, '\n',
  @dropOldTriggersSection, '\n',
  @renameBaseTablesSection, '\n',
  @createProceduresSection, '\n',
  @createFunctionsSection, '\n',
  @createViewsSection, '\n',
  @createTriggersSection, '\n',
  @createEventsSection, '\n',
  @grantSection, '\n',
  @dropOldViewsSection, '\n',
  @dropOldEventsSection, '\n',
  @dropOldRoutinesSection, '\n',
  @footerSection
  )
) AS rename_script;
