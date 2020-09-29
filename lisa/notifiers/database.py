import logging
import pyodbc
import sys

from string import Template
from dataclasses import dataclass, field
from typing import List, Type, cast, Dict

from dataclasses_json import LetterCase, dataclass_json  # type: ignore

from lisa import notifier, schema
from lisa.testsuite import TestResultMessage


@dataclass_json(letter_case=LetterCase.CAMEL)
@dataclass
class DataBaseSchema(schema.TypedSchema):
    log_level: str = logging.getLevelName(logging.DEBUG)
    driver: str = field(default="")
    server: str = field(default="")
    database: str = field(default="")
    username: str = field(default="")
    password: str = field(default="")
    tablename: str = field(default="")


class DataBase(notifier.Notifier):
    """
    It's a sample notifier, output subscribed message to database.
    """

    @classmethod
    def type_name(cls) -> str:
        return "database"

    @classmethod
    def type_schema(cls) -> Type[schema.TypedSchema]:
        return DataBaseSchema

    def get_connection_string(self) -> str:
        """Constructs the connection string for the DB"""
        connection_string = Template(
            "Driver={$SQLDriver};"
            "Server=$server,$port;"
            "Database=$db_name;"
            "Uid=$db_user;"
            "Pwd=$db_password;"
            "Encrypt=$encrypt;"
            "TrustServerCertificate=$certificate;"
            "Connection Timeout=$timeout;"
        )

        return connection_string.substitute(
            SQLDriver=self._runbook.driver,
            server=self._runbook.server,
            db_name=self._runbook.database,
            db_user=self._runbook.username,
            db_password=self._runbook.password,
        )

    def _initialize(self) -> None:
        connection = pyodbc.connect(self.get_connection_string())
        self._cursor = connection.cursor()

    def finalize(self) -> None:
        self._cursor.close()

    def insert_values(self, values_dict: Dict[str, str]) -> None:
        """Creates an insert command from a template and calls the pyodbc method.
        Provided with a dictionary that is structured so the keys match the
        column names and the values are represented by the items that are to be
        inserted the function composes the sql command from a template and
        calls a pyodbc to execute the command.
        """
        insert_command_template = Template(
            "insert into $tableName($columns) values($values)"
        )
        self._log.debug("Line to be inserted %s", values_dict)
        values = ""
        table_name = '"' + self._runbook.tablename + '"'
        for item in values_dict.values():
            values = ", ".join([str(values), "'" + str(item) + "'"])

        insert_command = insert_command_template.substitute(
            tableName=table_name,
            columns=", ".join(values_dict.keys()),
            values=values[1:],
        )

        self._log.debug("Insert command that will be exectued:")
        self._log.debug(insert_command)

        try:
            self._cursor.execute(insert_command)
        except pyodbc.DataError as data_error:
            print(dir(data_error))
            if data_error[0] == "22001":
                self._log.error("Value to be inserted exceeds column size limit")
            else:
                self._log.error("Database insertion error", exc_info=True)

            self._log.debug("Terminating execution")
            sys.exit(0)

    def update_values(
        self, values_dict: Dict[str, str], composite_keys: List[str]
    ) -> None:
        """Creates an update command from a template and calls the pyodbc method.
        Provided with a dictionary that is structured so the keys match the
        column names and the values are represented by the items that are to be
        inserted the function composes the sql command from a template and
        calls a pyodbc to execute the command.
        """
        update_command_template = Template(
            """
            IF (NOT EXISTS(SELECT * FROM $tableName WHERE $compositeConditions))
            BEGIN
                INSERT INTO $tableName($columns) VALUES($insertValues)
            END
            ELSE
            BEGIN
                UPDATE TOP(1) $tableName SET $updateValues WHERE $compositeConditions
            END
        """
        )
        self._log.debug("Line to be update %s", values_dict)
        insert_values = ""
        update_values = ""
        composite_conditions = ""
        table_name = '"' + self._runbook.tablename + '"'
        for k, v in values_dict.items():
            insert_values = ", ".join([str(insert_values), "'" + str(v) + "'"])
            update_values = ", ".join(
                [str(update_values), str(k) + " = " + "'" + str(v) + "'"]
            )
            if k in composite_keys:
                composite_conditions = " AND ".join(
                    [str(composite_conditions), str(k) + " = " + "'" + str(v) + "'"]
                )

        update_command = update_command_template.substitute(
            tableName=table_name,
            columns=", ".join(values_dict.keys()),
            insertValues=insert_values[1:],
            updateValues=update_values[1:],
            compositeConditions=composite_conditions[5:],
        )

        self._log.debug("Update command that will be exectued:")
        self._log.debug(update_command)

        try:
            self._cursor.execute(update_command)
        except pyodbc.DataError as data_error:
            print(dir(data_error))
            if data_error[0] == "22001":
                self._log.error("Value to be updated exceeds column size limit")
            else:
                self._log.error("Database update error", exc_info=True)

            self._log.debug("Terminating execution")
            sys.exit(0)

    def select_table(self, column: str, value: str) -> None:
        self._cursor.execute(
            "select * from %s where %s=%s" % (self._runbook.tablename, column, value)
        )
        for row in self._cursor:
            print(row)

    def _received_message(self, message: notifier.MessageBase) -> None:
        runbook = cast(DataBaseSchema, self._runbook)
        self.select_table("ID", "1")
        self._log.log(
            getattr(logging, runbook.log_level),
            f"received message [{message.type}]: {message}",
        )

    def _subscribed_message_type(self) -> List[Type[notifier.MessageBase]]:
        return [TestResultMessage]
