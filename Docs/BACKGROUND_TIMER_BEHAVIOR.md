# Background Timer Behavior

An ordinary in-memory timer is not sufficient while iOS suspends an application. Muzik Belesh persists a wall-clock deadline and reconciles it on launch and lifecycle checkpoints. During supported background audio execution, the service can reach the deadline and pause AVPlayer; if iOS suspends or terminates the process, exact callback timing cannot be guaranteed and the next reconciliation is authoritative.
