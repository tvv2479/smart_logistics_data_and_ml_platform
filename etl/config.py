import os
from dataclasses import dataclass

from dotenv import load_dotenv

load_dotenv()

@dataclass(frozen=True)
class Config:
    db_host: str = os.getenv("PGHOST", "localhost")
    db_port: int = int(os.getenv("PGPORT", "5432"))
    db_name: str = os.getenv("PGDATABASE", "test")
    db_user: str = os.getenv("PGUSER", "vit")
    db_password: str = os.getenv("PGPASSWORD", "listopad")
    as_of: str = os.getenv("AS_OF_DATE", "2026-10-26")

    @property
    def dsn(self) -> str:
        return (
            f"postgresql://{self.db_user}:{self.db_password}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )