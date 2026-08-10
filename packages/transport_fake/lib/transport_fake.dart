/// Deterministic in-memory mesh simulator.
///
/// Exists so mesh behaviour — flooding, suppression, store-and-forward,
/// delivery under loss and partition — is testable in ordinary unit tests with
/// no radios, no devices and no wall-clock waiting.
library;

export 'src/mesh_simulator.dart';
export 'src/sim_node.dart';
