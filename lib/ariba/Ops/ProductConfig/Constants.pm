package ariba::Ops::ProductConfig::Constants;

use strict;
use warnings;
use Exporter qw(import);

### constants that will be automatically imported to calling namespace
our @EXPORT_OK = qw(TRUE FALSE LOGDIR UPLOAD_MAX_AGE GENCONFIG_MAX_AGE MON_TABLE APP_TABLE
                    GENCONFIG_TMPDIR HANA_TYPE ORACLE_TYPE %VALID_DBTYPES @DBTYPES);
our %EXPORT_TAGS = (all => [@EXPORT_OK]);

use constant LOGDIR => qq(/tmp); # log basedir
use constant GENCONFIG_TMPDIR => qq(/tmp/tools_dpc);

### these age limits are currently be used only in Hana module but should be considered for all.
use constant UPLOAD_MAX_AGE   =>  3600; # don't upload extracted disk data if older than this num of secs
use constant GENCONFIG_MAX_AGE => 86400; # don't gen configs for mondb records older than this num of secs

use constant MON_TABLE => 'product_config';
use constant APP_TABLE => 'monitor_tools.app_name';

### for now we're tracking known db types here.
### in the future we'll divine this info dynamically.
use constant {
    HANA_TYPE   => 'hana',
    ORACLE_TYPE => 'oracle',
};
our %VALID_DBTYPES = (
    HANA_TYPE()   => HANA_TYPE,
    ORACLE_TYPE() => ORACLE_TYPE,
);
our @DBTYPES = keys %VALID_DBTYPES;

use constant { TRUE  => 1, FALSE => 0 };

use constant PC_TABLE_NAME => qw(product_config);

# if these flags are set, then no need to monitor these SRS servers, instead show a warning with these text
use constant SRS_FLAGS => 'yes_maintenance|provisioning';

use constant CREATE_PRODUCT_CONFIG_TABLE => qq(CREATE TABLE product_config
            (
                sid                     VARCHAR2(20 CHAR) NOT NULL,
                vip                     VARCHAR2(80 CHAR),
                db_name                 VARCHAR2(20 CHAR),
                sql_port                VARCHAR2(10 CHAR),
                app_name                VARCHAR2(100 CHAR),
                mon_host                VARCHAR2(50 CHAR) NOT NULL,
                app_dbtype              VARCHAR2(20 CHAR) NOT NULL,
                host_primary            VARCHAR2(50 CHAR),
                host_failover           VARCHAR2(400 CHAR),
                host_slave              VARCHAR2(400 CHAR),
                source_host             VARCHAR2(50 CHAR) NOT NULL,
                last_updated            DATE DEFAULT sysdate,
                enabled                 VARCHAR2(1 CHAR) DEFAULT 'N',
                admin_id                VARCHAR2(80 CHAR),

                CONSTRAINT product_config_unique UNIQUE (sid,app_name, vip, db_name,host_primary)
            ) );

TRUE;
