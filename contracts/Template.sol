/*
 * SPDX-License-Identitifer:    GPL-3.0-or-later
 *
 * This file requires contract dependencies which are licensed as
 * GPL-3.0-or-later, forcing it to also be licensed as such.
 *
 * This is the only file in your project that requires this license and
 * you are free to choose a different license for the rest of the project.
 */

pragma solidity 0.4.24;

import "@aragon/os/contracts/factory/DAOFactory.sol";
import "@aragon/os/contracts/apm/Repo.sol";
import "@aragon/os/contracts/lib/ens/ENS.sol";
import "@aragon/os/contracts/lib/ens/PublicResolver.sol";
import "@aragon/os/contracts/apm/APMNamehash.sol";

import "@aragon/apps-token-manager/contracts/TokenManager.sol";
import "@aragon/apps-voting/contracts/Voting.sol";
import "@aragon/apps-shared-minime/contracts/MiniMeToken.sol";
import "@aragon/apps-agent/contracts/Agent.sol";
import "@aragon/apps-finance/contracts/Finance.sol";

import "./ICycleManager.sol";
import "./Airdrop.sol";


contract TemplateBase is APMNamehash {
    ENS public ens;
    DAOFactory public fac;

    event DeployDao(address dao);
    event InstalledApp(address appProxy, bytes32 appId);

    constructor(DAOFactory _fac, ENS _ens) public {
        ens = _ens;

        // If no factory is passed, get it from on-chain bare-kit
        if (address(_fac) == address(0)) {
            bytes32 bareKit = apmNamehash("bare-kit");
            fac = TemplateBase(latestVersionAppBase(bareKit)).fac();
        } else {
            fac = _fac;
        }
    }

    function latestVersionAppBase(bytes32 appId) public view returns (address base) {
        Repo repo = Repo(PublicResolver(ens.resolver(appId)).addr(appId));
        (,base,) = repo.getLatest();

        return base;
    }
}


contract Template is TemplateBase {
    MiniMeTokenFactory tokenFactory;

    Airdrop private airdrop;
    Voting private voting;
    TokenManager private tokenManager;
    ICycleManager private cycleManager;
    Agent private agent;
    Finance private finance;

    uint64 constant PCT = 10 ** 16;
    address constant ANY_ENTITY = address(-1);

    constructor(ENS ens) TemplateBase(DAOFactory(0), ens) public {
        tokenFactory = new MiniMeTokenFactory();
    }

    function newInstance(address[] _holders) public {
    /* function newInstance() public { */

        airdrop = Airdrop(0);
        voting = Voting(0);
        tokenManager = TokenManager(0);
        cycleManager = ICycleManager(0);
        agent = Agent(0);
        finance = Finance(0);

        Kernel dao = fac.newDAO(this);
        ACL acl = ACL(dao.acl());
        acl.createPermission(this, dao, dao.APP_MANAGER_ROLE(), this);

        address root = msg.sender;
        bytes32 airdropAppId = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("airdrop-app")));
        bytes32 votingAppId = apmNamehash("voting");
        bytes32 tokenManagerAppId = apmNamehash("token-manager");

        airdrop = Airdrop(dao.newAppInstance(airdropAppId, latestVersionAppBase(airdropAppId)));
        voting = Voting(dao.newAppInstance(votingAppId, latestVersionAppBase(votingAppId)));
        tokenManager = TokenManager(dao.newAppInstance(tokenManagerAppId, latestVersionAppBase(tokenManagerAppId)));
        cycleManager = _setupCycleManager(dao, acl, voting);
        agent = _setupAgent(dao, acl, voting);
        finance = _setupFinance(dao, acl, agent, voting);

        MiniMeToken token = tokenFactory.createCloneToken(MiniMeToken(0), 0, "Guardian", 18, "GUARD", false);
        token.changeController(tokenManager);

        // Initialize apps
        tokenManager.initialize(token, false, 0);
        emit InstalledApp(tokenManager, tokenManagerAppId);
        voting.initialize(token, uint64(60*10**16), uint64(15*10**16), uint64(1 days));
        emit InstalledApp(voting, votingAppId);
        airdrop.initialize(tokenManager, agent, cycleManager);
        emit InstalledApp(airdrop, airdropAppId);

        /* acl.createPermission(voting, voting, voting.MODIFY_SUPPORT_ROLE(), voting); */
        /* acl.createPermission(voting, voting, voting.MODIFY_QUORUM_ROLE(), voting); */
        acl.createPermission(tokenManager, voting, voting.CREATE_VOTES_ROLE(), voting);
        acl.createPermission(voting, tokenManager, tokenManager.BURN_ROLE(), voting);
        acl.createPermission(ANY_ENTITY, airdrop, airdrop.START_ROLE(), voting);
        acl.createPermission(this, tokenManager, tokenManager.MINT_ROLE(), this);

        // Agent permissions
        acl.createPermission(finance, agent, agent.TRANSFER_ROLE(), address(this));
        acl.grantPermission(airdrop, agent, agent.TRANSFER_ROLE());
        acl.setPermissionManager(voting, agent, agent.TRANSFER_ROLE());

        for (uint i=0; i<_holders.length; i++) {
            tokenManager.mint(_holders[i], 1e18); // Give 1 token to each holder
        }

        // Clean up permissions
        acl.grantPermission(airdrop, tokenManager, tokenManager.MINT_ROLE());
        acl.revokePermission(this, tokenManager, tokenManager.MINT_ROLE());
        acl.setPermissionManager(voting, tokenManager, tokenManager.MINT_ROLE());

        acl.grantPermission(voting, dao, dao.APP_MANAGER_ROLE());
        acl.revokePermission(this, dao, dao.APP_MANAGER_ROLE());
        acl.setPermissionManager(voting, dao, dao.APP_MANAGER_ROLE());

        acl.grantPermission(voting, acl, acl.CREATE_PERMISSIONS_ROLE());
        acl.revokePermission(this, acl, acl.CREATE_PERMISSIONS_ROLE());
        acl.setPermissionManager(voting, acl, acl.CREATE_PERMISSIONS_ROLE());

        emit DeployDao(dao);
    }

    function _setupAgent(Kernel _dao, ACL _acl, Voting _voting) internal returns (Agent) {
        bytes32 appId = apmNamehash("agent");
        return Agent(_dao.newAppInstance(appId, latestVersionAppBase(appId)));
    }

    function _setupFinance(Kernel _dao, ACL _acl, Agent _agent, Voting _voting) internal returns (Finance) {
        bytes32 appId = apmNamehash("finance");
        Finance finance = Finance(_dao.newAppInstance(appId, latestVersionAppBase(appId)));
        finance.initialize(_agent, uint64(1 days));
        _acl.createPermission(ANY_ENTITY, finance, finance.CREATE_PAYMENTS_ROLE(), _voting);
        return finance;
    }

    function _setupCycleManager(Kernel _dao, ACL _acl, Voting _voting) internal returns (ICycleManager) {
        bytes32 appId = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("cycle-manager")));
        bytes memory initializeData = abi.encodeWithSelector(ICycleManager(0).initialize.selector, 60);
        address latestBaseAppAddress = latestVersionAppBase(appId);
        ICycleManager cycleManager = ICycleManager(_dao.newAppInstance(appId, latestBaseAppAddress, initializeData, false));

        _acl.createPermission(ANY_ENTITY, cycleManager, cycleManager.UPDATE_CYCLE_ROLE(), _voting);

        return cycleManager;
    }

}
