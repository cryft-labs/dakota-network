import java.nio.file.*;
import java.util.*;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.hyperledger.besu.config.*;
import org.hyperledger.besu.consensus.common.*;
import org.hyperledger.besu.consensus.qbft.*;
import org.hyperledger.besu.datatypes.Hash;
import org.hyperledger.besu.ethereum.chain.*;
import org.hyperledger.besu.ethereum.core.MiningConfiguration;
import org.hyperledger.besu.ethereum.mainnet.*;
import org.hyperledger.besu.evm.internal.EvmConfiguration;
import org.hyperledger.besu.metrics.noop.NoOpMetricsSystem;

class MilestoneProbe {
  public static void main(String[] args) throws Exception {
    var mapper = new ObjectMapper();
    for (int i=1; i<args.length; i++) {
      var genesis = GenesisConfig.fromConfig(Files.readString(Path.of(args[i])));
      var config = genesis.getConfigOptions();
      var forks = new ForksSchedule<>(List.of(new ForkSpec<>(0, config.getQbftConfigOptions())));
      var schedule = QbftProtocolScheduleBuilder.create(config, forks, new QbftExtraDataCodec(),
          EvmConfiguration.DEFAULT, MiningConfiguration.newDefault(), new BadBlockManager(),
          false, BalConfiguration.DEFAULT, new NoOpMetricsSystem(), 64000000L);
      var block = GenesisState.fromStorage(Hash.fromHexString(args[0]), genesis, schedule).getBlock();
      var spec = schedule.getByBlockHeader(block.getHeader());
      var out = new TreeMap<String,Object>();
      out.put("file", Path.of(args[i]).getFileName().toString());
      out.put("milestones", schedule.listMilestones().toString());
      out.put("genesisBlockHash", block.getHash().toHexString());
      out.put("hardfork", spec.getHardforkId().name());
      out.put("finalized", spec.getHardforkId().finalized());
      out.put("maxCodeSize", spec.getEvm().getMaxCodeSize());
      out.put("maxInitcodeSize", spec.getEvm().getMaxInitcodeSize());
      out.put("evm", spec.getEvm().getEvmVersion().name());
      out.put("blobGasLimit", spec.getGasLimitCalculator().currentBlobGasLimit());
      out.put("targetBlobGasPerBlock", spec.getGasLimitCalculator().getTargetBlobGasPerBlock());
      out.put("blockReward", spec.getBlockReward().toString());
      out.put("isPoS", spec.isPoS());
      out.put("slotNumberRequired", spec.isSlotNumberRequired());
      out.put("blockAccessListEnabled", spec.isBlockAccessListEnabled());
      for (String name : List.of("getGasCalculator", "getGasLimitCalculator", "getFeeMarket",
          "getTransactionProcessor", "getBlockProcessor", "getBlockBodyValidator",
          "getWithdrawalsValidator", "getBlockGasAccountingStrategy", "getBlockGasUsedValidator")) {
        out.put(name, spec.getClass().getMethod(name).invoke(spec).getClass().getName());
      }
      System.out.println("PROBE_JSON="+mapper.writeValueAsString(out));
    }
  }
}
