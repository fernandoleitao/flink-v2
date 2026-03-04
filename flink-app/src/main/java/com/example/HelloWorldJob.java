package com.example;

import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.streaming.api.functions.source.legacy.SourceFunction;

public class HelloWorldJob {

    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.addSource(new HelloWorldSource())
           .print();
        env.execute("Hello World Job");
    }

    public static class HelloWorldSource implements SourceFunction<String> {
        private volatile boolean isRunning = true;
        private long counter = 0;

        @Override
        public void run(SourceContext<String> ctx) throws Exception {
            while (isRunning) {
                counter++;
                ctx.collect("Hello World #" + counter);
                Thread.sleep(1000);
            }
        }

        @Override
        public void cancel() {
            isRunning = false;
        }
    }
}
