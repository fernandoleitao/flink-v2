FROM apache/flink:2.0.1-java21
COPY flink-app/target/hello-world-flink-1.0.jar /opt/flink/usrlib/hello-world.jar
