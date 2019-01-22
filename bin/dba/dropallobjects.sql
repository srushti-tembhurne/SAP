--
-- WARNING - THIS SCRIPT WILL COMPLETELY DROP EVERYTHING!!!
--

DECLARE
  TB NUMBER;
BEGIN
  FOR tab IN (SELECT table_name FROM USER_TABLES) LOOP
    EXECUTE IMMEDIATE '
DECLARE
  TN NUMBER;
BEGIN
  SELECT COUNT(*) INTO TN FROM USER_TABLES WHERE TABLE_NAME = ''' || tab.table_name || ''';
  IF (TN > 0) THEN
    EXECUTE IMMEDIATE ''DROP TABLE ' || tab.table_name || ' CASCADE CONSTRAINTS'';
  END IF;
END;
';
  END LOOP;
END;
/

BEGIN
  FOR seq IN (SELECT sequence_name FROM USER_SEQUENCES) LOOP
    EXECUTE IMMEDIATE 'DROP SEQUENCE ' || seq.sequence_name;
  END LOOP;
END;
/

BEGIN
  FOR pkg IN (SELECT OBJECT_NAME FROM USER_OBJECTS WHERE OBJECT_TYPE = 'PACKAGE') LOOP
    EXECUTE IMMEDIATE 'DROP PACKAGE ' || pkg.object_name;
  END LOOP;
END;
/

BEGIN 
  FOR proc IN (SELECT OBJECT_NAME FROM USER_OBJECTS WHERE OBJECT_TYPE = 'PROCEDURE') LOOP
    EXECUTE IMMEDIATE 'DROP PROCEDURE ' || proc.object_name;
  END LOOP;
END;
/

BEGIN 
  FOR proc IN (SELECT OBJECT_NAME FROM USER_OBJECTS WHERE OBJECT_TYPE = 'FUNCTION') LOOP
    EXECUTE IMMEDIATE 'DROP FUNCTION ' || proc.object_name;
  END LOOP;
END;
/

BEGIN 
  FOR v IN (SELECT VIEW_NAME FROM USER_VIEWS) LOOP
    EXECUTE IMMEDIATE 'DROP VIEW ' || v.view_name;
  END LOOP;
END;
/

BEGIN 
  FOR t IN (SELECT TYPE_NAME FROM USER_TYPES) LOOP
    EXECUTE IMMEDIATE 'DROP TYPE ' || t.type_name;
  END LOOP;
END;
/

BEGIN 
  FOR syn IN (SELECT SYNONYM_NAME FROM USER_SYNONYMS) LOOP
    EXECUTE IMMEDIATE 'DROP SYNONYM ' || syn.synonym_name;
  END LOOP;
END;
/
