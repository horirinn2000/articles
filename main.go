package main

import (
	"fmt"
	"net/http"

	"github.com/google/uuid"
)

func main() {
	fmt.Println("Hello, World!" + uuid.New().String())

	http.ListenAndServe(":8080", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "Hello, World!"+uuid.New().String())
	}))
}
