package org.springframework.samples.petclinic.web;

import org.junit.jupiter.api.Test;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.samples.petclinic.model.Pet;
import org.springframework.samples.petclinic.model.Visit;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * The flatpickr date format in the forms must produce what the model's @DateTimeFormat accepts,
 * otherwise a date picked from the calendar fails to bind.
 */
class DatePickerFormatTests {

    private static final String JSP_DIR = "src/main/webapp/WEB-INF/jsp/pets/";

    @Test
    void petFormPickerMatchesBirthDatePattern() throws Exception {
        assertThat(pattern(Pet.class, "birthDate")).isEqualTo("yyyy/MM/dd");
        assertThat(Files.readString(Path.of(JSP_DIR + "createOrUpdatePetForm.jsp")))
            .contains("flatpickr(\"#birthDate\", {dateFormat: \"Y/m/d\"})");
    }

    @Test
    void visitFormPickerMatchesDatePattern() throws Exception {
        assertThat(pattern(Visit.class, "date")).isEqualTo("yyyy/MM/dd");
        assertThat(Files.readString(Path.of(JSP_DIR + "createOrUpdateVisitForm.jsp")))
            .contains("flatpickr(\"#date\", {dateFormat: \"Y/m/d\"})");
    }

    private static String pattern(Class<?> type, String field) throws NoSuchFieldException {
        return type.getDeclaredField(field).getAnnotation(DateTimeFormat.class).pattern();
    }
}
