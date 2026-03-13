package com.example;

public class App {
    public String getGreeting() {
        return "Hello from Java 25!";
    }

    public static void main(String[] args) {
        System.out.println(new App().getGreeting());
    }
}
