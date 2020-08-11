from __future__ import annotations

from abc import ABCMeta
from typing import TYPE_CHECKING, List

from lisa.core.action import Action
from lisa.core.actionStatus import ActionStatus
from lisa.util.logger import log

if TYPE_CHECKING:
    from lisa.core.testFactory import TestSuiteMetadata
    from lisa.core.environment import Environment


class TestSuite(Action, metaclass=ABCMeta):
    def __init__(
        self,
        environment: Environment,
        cases: List[str],
        suiteMetadata: TestSuiteMetadata,
    ) -> None:
        self.environment = environment
        self.cases = cases
        self.suiteMetadata = suiteMetadata
        self.shouldStop = False

    @property
    def skipRun(self) -> bool:
        return False

    def beforeSuite(self) -> None:
        pass

    def afterSuite(self) -> None:
        pass

    def beforeCase(self) -> None:
        pass

    def afterCase(self) -> None:
        pass

    def getTypeName(self) -> str:
        return "TestSuite"

    async def start(self) -> None:
        if self.skipRun:
            log.info(f"suite[{self.suiteMetadata.name}] skipped on this run")
            return
        self.beforeSuite()
        for test_case in self.cases:
            self.beforeCase()
            test_method = getattr(self, test_case)
            test_method()
            self.afterCase()
            if self.shouldStop:
                log.info("received stop message, stop run")
                self.setStatus(ActionStatus.STOPPED)
                break
        self.afterSuite()

    async def stop(self) -> None:
        self.setStatus(ActionStatus.STOPPING)
        self.shouldStop = True

    async def close(self) -> None:
        pass