package main

import (
	"os"

	"github.com/TableProApp/TablePro/Native/HanaBridge/internal/hana"
)

func main() {
	os.Exit(run(os.Stdin, os.Stdout, hana.NewBridge()))
}
